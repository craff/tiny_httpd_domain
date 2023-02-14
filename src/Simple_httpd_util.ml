
external raw_single_write : Unix.file_descr -> Bytes.t -> int -> int -> int = "caml_fast_single_write" [@@noalloc]

external write_error : unit -> 'a = "caml_write_error"

let single_write fd buf ofs len =
  if ofs < 0 || len < 0 || ofs+len > Bytes.length buf then
    invalid_arg "single_write";
  let ret = raw_single_write fd buf ofs len in
  if ret == -1 then write_error();
  ret

external raw_read : Unix.file_descr -> Bytes.t -> int -> int -> int = "caml_fast_read" [@@noalloc]

external read_error : unit -> 'a = "caml_read_error"

let read fd buf ofs len =
  if ofs < 0 || len < 0 || ofs+len > Bytes.length buf then
    invalid_arg "read";
  let ret = raw_read fd buf ofs len in
  if ret == -1 then read_error();
  ret

(* test utils *)
(*$inject
  let pp_res f = function Ok x -> f x | Error e -> e
  let pp_res_query = (Q.Print.(pp_res (list (pair string string))))
  let err_map f = function Ok x-> Ok (f x) | Error e -> Error e
  let sort_l l = List.sort compare l
  let eq_sorted a b = (=) (err_map sort_l a)(err_map sort_l b)
  let is_ascii_char c = Char.code c < 128
*)

external setsockopt_cork : Unix.file_descr -> bool -> unit = "caml_setsockopt_cork"

external raw_sendfile : Unix.file_descr -> Unix.file_descr -> int -> int -> int
  = "caml_sendfile" [@@noalloc]

external sendfile_error : unit -> 'a = "caml_sendfile_error"

let sendfile out in_ offset count =
  let ret = raw_sendfile out in_ offset count in
  if ret == -1 then sendfile_error ();
  ret

let percent_encode ?(skip=fun _->false) s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | c when skip c -> Buffer.add_char buf c
      | (' ' | '!' | '"' | '#' | '$' | '%' | '&' | '\'' | '(' | ')' | '*' | '+'
        | ',' | '/' | ':' | ';' | '=' | '?' | '@' | '[' | ']' | '~')
        as c ->
        Printf.bprintf buf "%%%X" (Char.code c)
      | c when Char.code c > 127 ->
        Printf.bprintf buf "%%%X" (Char.code c)
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(*$= & ~printer:(fun s->s)
  "hello%20world" (percent_encode "hello world")
  "%23%25^%24%40^%40" (percent_encode "#%^$@^@")
  "a%20ohm%2B5235%25%26%40%23%20---%20_" (percent_encode "a ohm+5235%&@# --- _")
*)

(*$= & ~printer:Q.(Print.string)
  ("?") (percent_decode @@ percent_encode "?")
*)

let hex_int (s:string) : int = Scanf.sscanf s "%x" (fun x->x)

let percent_decode (s:string) =
  let buf = Buffer.create (String.length s) in
  let i = ref 0 in
  while !i < String.length s do
    match String.get s !i with
    | '%' ->
       if !i+2 < String.length s then (
         begin match hex_int @@ String.sub s (!i+1) 2 with
         | n -> Buffer.add_char buf (Char.chr n)
         | exception _ -> invalid_arg "percent_decode"
         end;
         i := !i + 3;
       ) else (
         raise Exit (* truncated *)
       )
    | '+' -> Buffer.add_char buf ' '; incr i (* for query strings *)
    | c -> Buffer.add_char buf c; incr i
  done;
  Buffer.contents buf

(*$QR & ~count:1_000 ~long_factor:20
    Q.string (fun s ->
        String.iter (fun c -> Q.assume @@ is_ascii_char c) s;
        percent_decode (percent_encode s) = s ||
          Q.Test.fail_report "invalid percent encoding")
*)

exception Invalid_query

let find_q_index_ s = String.index s '?'

let get_non_query_path s =
  match find_q_index_ s with
  | i -> String.sub s 0 i
  | exception Not_found -> s

let get_query s : string =
  match find_q_index_ s with
  | i -> String.sub s (i+1) (String.length s-i-1)
  | exception Not_found -> ""

let split_query s = get_non_query_path s, get_query s

let split_on_slash s : _ list =
  let l = ref [] in
  let i = ref 0 in
  let n = String.length s in
  while !i < n do
    match String.index_from s !i '/' with
    | exception Not_found ->
      if !i < n then (
        (* last component *)
        l := String.sub s !i (n - !i) :: !l;
      );
      i := n (* done *)
    | j ->
      if j > !i then  (
        l := String.sub s !i (j - !i) :: !l;
      );
      i := j+1;
  done;
  List.rev !l

(*$= & ~printer:Q.Print.(list string)
  ["a"; "b"] (split_on_slash "/a/b")
  ["coucou"; "lol"] (split_on_slash "/coucou/lol")
  ["a"; "b"; "c"] (split_on_slash "/a/b//c/")
  ["a"; "b"] (split_on_slash "//a/b/")
  ["a"] (split_on_slash "/a//")
  [] (split_on_slash "/")
  [] (split_on_slash "//")
*)

let parse_query s : (_ list, string) result=
  let pairs = ref [] in
  let is_sep_ = function '&' | ';' -> true | _ -> false in
  let i = ref 0 in
  let j = ref 0 in
  try
    let percent_decode s =
      try percent_decode s with _ -> raise Invalid_query
    in
    let parse_pair () =
      let eq = String.index_from s !i '=' in
      let k = percent_decode @@ String.sub s !i (eq- !i) in
      let v = percent_decode @@ String.sub s (eq+1) (!j-eq-1) in
      pairs := (k,v) :: !pairs;
    in
    while !i < String.length s do
      while !j < String.length s && not (is_sep_ (String.get s !j)) do incr j done;
      if !j < String.length s then (
        assert (is_sep_ (String.get s !j));
        parse_pair();
        i := !j+1;
        j := !i;
      ) else (
        parse_pair();
        i := String.length s; (* done *)
      )
    done;
    Ok !pairs
  with
  | Invalid_argument _ | Not_found | Failure _ ->
    Error (Printf.sprintf "error in parse_query for %S: i=%d,j=%d" s !i !j)
  | Invalid_query -> Error ("invalid query string: " ^ s)

(*$= & ~printer:pp_res_query ~cmp:eq_sorted
  (Ok ["a", "b"; "c", "d"]) (parse_query "a=b&c=d")
*)

(*$QR & ~long_factor:20 ~count:1_000
    Q.(small_list (pair string string))
      (fun l ->
        List.iter (fun (a,b) ->
            Q.assume (a<>"" && b<>"" );
            String.iter (fun c -> Q.assume @@ is_ascii_char c) a;
            String.iter (fun c -> Q.assume @@ is_ascii_char c) b;
          ) l;
        let s = String.concat "&"
            (List.map (fun (x,y) -> percent_encode x ^"="^percent_encode y) l) in
        eq_sorted (Ok l) (parse_query s))
*)

let pp_date fmt date =
  let open Unix in
  let day = match date.tm_wday with
    | 0 -> "Sun"
    | 1 -> "Mon"
    | 2 -> "Tue"
    | 3 -> "Wed"
    | 4 -> "Thu"
    | 5 -> "Fri"
    | 6 -> "Sat"
    | _ -> invalid_arg "print_date"
  in
  let month = match date.tm_mon with
    | 0 -> "Jan"
    | 1 -> "Feb"
    | 2 -> "Mar"
    | 3 -> "Apr"
    | 4 -> "May"
    | 5 -> "Jun"
    | 6 -> "Jul"
    | 7 -> "Aug"
    | 8 -> "Sep"
    | 9 -> "Oct"
    |10 -> "Nov"
    |11 -> "Dec"
    | _ -> invalid_arg "print_date"
  in
  Format.fprintf fmt "%s, %02d %s %04d %02d:%02d:%02d GMT"
    day date.tm_mday month (date.tm_year+1900) date.tm_hour date.tm_min date.tm_sec

module LinkedList = struct

  type 'a cell =
    | Nil
    | Cons of { v : 'a
              ; mutable next : 'a cell
              ; mutable prev : 'a cell }

  type 'a t = { mutable head : 'a cell
              ; mutable tail : 'a cell }

  let create () = { head = Nil; tail = Nil }

  let is_cell = function
    | Nil -> false
    | Cons _ -> true

  let is_empty l = not (is_cell l.head)

  let get = function
    | Nil -> raise Not_found
    | Cons { v; _ } -> v

  let head l = l.head
  let tail l = l.tail
  let next l = match l with
    | Nil -> raise Not_found
    | Cons r -> r.next
  let prev l = match l with
    | Nil -> raise Not_found
    | Cons r -> r.prev

  let size l =
    let rec fn acc = function
      | Nil -> acc
      | Cons { next; _ } -> fn (acc+1) next
    in
    fn 0 l.head

  let add_first v l =
    let cell = Cons { v; next = l.head; prev = Nil } in
    (match l.head with
    | Nil    -> assert (l.tail = Nil);
                l.head <- cell; l.tail <- cell
    | Cons r -> r.prev <- cell; l.head <- cell);
    cell

  let add_last v l =
    let cell = Cons { v; next = Nil; prev = l.tail } in
    (match l.tail with
    | Nil    -> assert (l.head = Nil);
                l.head <- cell; l.tail <- cell
    | Cons r -> r.next <- cell; l.tail <- cell);
    cell

  let remove_cell : 'a cell -> 'a t -> unit =
    fun c l ->
      match c with
      | Nil -> invalid_arg "LinkedList.remove_cell"
      | Cons r ->
         (match r.prev with
          | Nil -> assert (l.head == c); l.head <- r.next
          | Cons p -> p.next <- r.next; r.next <- Nil);
         (match r.next with
          | Nil -> assert (l.tail == c); l.tail <- r.prev
          | Cons n -> n.prev <- r.prev; r.prev <- Nil)

  let insert_first : 'a cell -> 'a t -> unit =
    fun c l ->
          match c with
      | Nil -> invalid_arg "LinkedList.insert_first"
      | Cons r ->
         assert (r.next = Nil);
         assert (r.prev = Nil);
         r.next <- l.head;
         (match l.head with
          | Nil -> l.tail <- c
          | Cons r' -> r'.prev <- c);
         l.head <- c

  let move_first : 'a cell -> 'a t -> unit =
    fun c l -> remove_cell c l; insert_first c l

  let insert_last : 'a cell -> 'a t -> unit =
    fun c l ->
          match c with
      | Nil -> invalid_arg "LinkedList.insert_first"
      | Cons r ->
         assert (r.next = Nil);
         assert (r.prev = Nil);
         r.prev <- l.tail;
         (match l.tail with
          | Nil -> l.head <- c
          | Cons r' -> r'.next <- c);
         l.tail <- c

  let move_last : 'a cell -> 'a t -> unit =
    fun c l -> remove_cell c l; insert_last c l

  type 'a prev = Cell of 'a cell | Root of 'a t

  let search_and_remove fn fn' l =
    let rec gn prev = function
      | Nil -> ()
      | Cons{ v; next; _ } as cell ->
         if fn v then
           begin
             let cell = match prev with
              | Root r -> r.head <- next; Nil
              | Cell (Cons c as cell) -> c.next <- next; cell
              | Cell Nil -> assert false
             in
             begin
               match next with
               | Nil -> l.tail <- cell
               | Cons c -> c.prev <- cell
             end;
             fn' v;
           end
         else
           gn (Cell cell) next
    in
    gn (Root l) l.head

end
