open Response_code

let fail_raise = Headers.fail_raise
let log = Log.f

type body = String of string
          | Stream of
              { inp: Input.t
              ; synch:(unit -> unit) option
              ; close : Input.t -> unit }
           (** flush each part and call f if second arg is [Some f] *)
          | File of
              { fd : Util.Sfd.t
              ; size : int
              ; close : (Util.Sfd.t -> unit) }
                (** if using sendfile, one might want to maintain the fd open
                    for another request, sharing file descriptor would limit
                    the number of open files *)
          | Void

type t = {
    code: Response_code.t;
    headers: Headers.t;
    body: body;
    post: unit -> unit;
  }

let body self = self.body
let set_body body self = {self with body}
let set_headers headers self = {self with headers}
let headers self = self.headers
let update_headers f self = {self with headers=f self.headers}
let set_header k v self = {self with headers = Headers.set k v self.headers}
let set_code code self = {self with code}
let set_post post self = {self with post}
let get_post self = self.post

let make_raw ?(cookies=[]) ?(headers=[]) ?(post=fun () -> ()) ~code body : t =
  (* add content length to response *)
  let headers = Headers.set_cookies cookies headers in
  let body = if body = "" then Void else String body in
  { code; headers; body; post }

let make_raw_stream ?synch ?(close=Input.close) ?(cookies=[]) ?(headers=[]) ?(post=fun () -> ())
      ~code inp : t =
  (* do not add content length to response *)
  let headers = Headers.set Headers.Transfer_Encoding "chunked" headers in
  let headers = Headers.set_cookies cookies headers in
  let body = Stream{inp;synch;close} in
  Gc.finalise (fun _ -> try close inp with _ -> ()) inp;
  { code; headers; body; post }

let make_raw_file ?(cookies=[]) ?(headers=[]) ?(post=fun () -> ()) ?(close=Util.Sfd.close)
      ~code size fd : t =
  (* add content length to response *)
  let headers = Headers.set_cookies cookies headers in
  let m = Atomic.make false in
  let close fd = if Atomic.compare_and_set m false true then close fd in
  let body = File{size; fd; close} in
  (* Gc.finalise (fun _ -> try Unix.close fd with _ -> ()) close;*)
  { code; headers; body; post }

let make_void ?(cookies=[]) ?(headers=[]) ?(post=fun () -> ()) ~code () : t =
  let headers = Headers.set_cookies cookies headers in
  let headers = if Headers.(get Content_Type headers = None)
                   &&  Headers.(get Content_Length headers = None)
                then
                  Headers.(set Content_Length "0" headers) else headers
  in
  { code; headers; body=Void; post }

let make_string ?cookies ?headers ?post body =
  make_raw ?cookies ?headers ?post ~code:ok body

let make_stream ?synch ?close ?cookies ?headers ?post body =
  make_raw_stream ?synch ?close ?cookies ?headers ?post ~code:ok body

let make_file ?cookies ?headers ?post ?close n body =
  make_raw_file ?cookies ?headers ?post ?close ~code:ok n body

let make ?cookies ?headers ?post r : t = match r with
  | String body -> make_raw ?cookies ?headers ~code:ok body
  | Stream{inp;synch;close} -> make_raw_stream ?synch ~close ?cookies ?headers ~code:ok inp
  | File{size;fd=body;close}->
     make_raw_file ?cookies ?headers ?post ~code:ok ~close size body
  | Void -> make_void ?cookies ?headers ~code:ok ()

let fail ?cookies ?headers ?post ~code fmt =
  Printf.ksprintf (fun msg -> make_raw ?cookies ?headers ?post ~code msg) fmt

let pp out self : unit =
  let pp_body out = function
    | String s -> Format.fprintf out "%S" s
    | Stream _ -> Format.pp_print_string out "<stream>"
    | File   _ -> Format.pp_print_string out "<file>"
    | Void -> ()
  in
  Format.fprintf out "{@[code=%d;@ headers=[@[%a@]];@ body=%a@]}"
    (self.code :> int) Headers.pp self.headers pp_body self.body

let output_ meth (oc:Output.t) (self:t) : unit =
  Output.add_string oc "HTTP/1.1 ";
  Output.add_decimal oc (self.code :> int);
  Output.add_char oc ' ';
  Output.add_string oc (Response_code.descr self.code);
  Output.add_char oc '\r';
  Output.add_char oc '\n';
  let body = self.body in
  let headers =
    match body with
    | String "" | Void -> self.headers
    | String s ->
       Headers.set Headers.Content_Length (string_of_int (String.length s))
         self.headers
    | File{size;_} ->
       Headers.set Headers.Content_Length (string_of_int size) self.headers
    | Stream _ -> Headers.set Headers.Transfer_Encoding "chunked" self.headers
  in

  let self = {self with headers; body} in
  List.iter (fun (k,v) ->
      Output.add_string oc (Headers.to_string k);
      Output.add_char oc ':';
      Output.add_char oc ' ';
      Output.add_string oc v;
      Output.add_char oc '\r';
      Output.add_char oc '\n') headers;
  log (Req 2) (fun k->k "output response: %s"
                       (Format.asprintf "%a" pp {self with body=String "<…>"}));
  Output.add_string oc "\r\n";
  if meth = Method.HEAD then
    begin
      match body with
      | File {size=_; fd; close} -> close fd
      | Stream{inp; close; _} -> close inp
      | _ -> ()
    end
  else
    begin
      match body with
      | String "" | Void -> ()
      | String s         -> Output.output_str oc s
      | File {size; fd; close} ->
         (try Output.sendfile oc size (Util.Sfd.get fd); close fd
          with e -> close fd; raise e)
      | Stream {inp;synch;close} ->
         (try
            Output.output_chunked ?synch oc inp;
            close inp;
          with e -> close inp; raise e)
    end;
  Output.flush oc;
  self.post ()
