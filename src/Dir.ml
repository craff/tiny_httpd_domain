open Response_code
module Mutex = Async.Mutex

let log = Log.f

type dir_behavior =
  | Index | Lists | Index_or_lists | Forbidden

type config = {
  mutable download: bool;
  mutable dir_behavior: dir_behavior;
  mutable delete: bool;
  mutable upload: bool;
  mutable max_upload_size: int;
}

let default_config_ : config =
  { download=true;
    dir_behavior=Forbidden;
    delete=false;
    upload=false;
    max_upload_size = 10 * 1024 * 1024;
  }

let default_config () = default_config_
let config
    ?(download=default_config_.download)
    ?(dir_behavior=default_config_.dir_behavior)
    ?(delete=default_config_.delete)
    ?(upload=default_config_.upload)
    ?(max_upload_size=default_config_.max_upload_size)
    () : config =
  { download; dir_behavior; delete; upload; max_upload_size }

let contains_dot_dot s =
  try
    String.iteri
      (fun i c ->
         if c='.' && i+1 < String.length s && String.get s (i+1) = '.' then raise Exit)
      s;
    false
  with Exit -> true

(* Human readable size *)
let human_size (x:int) : string =
  if x >= 1_000_000_000 then Printf.sprintf "%d.%dG" (x / 1_000_000_000) ((x/1_000_000) mod 1_000_000)
  else if x >= 1_000_000 then Printf.sprintf "%d.%dM" (x / 1_000_000) ((x/1000) mod 1_000)
  else if x >= 1_000 then Printf.sprintf "%d.%dk" (x/1000) ((x/100) mod 100)
  else Printf.sprintf "%db" x

let header_html = Headers.Content_Type, "text/html"
let (//) = Filename.concat

let encode_path s = Util.percent_encode ~skip:(function '/' -> true|_->false) s

let is_hidden s = String.length s>0 && s.[0] = '.'

type dynamic = Html.chaml

type 'a content =
  | String of string * string option
  | Path   of string * (string * int) option
  | Dynamic of dynamic
  | Stream of Input.t
  | Fd of Unix.file_descr
  | Dir of 'a

type file_info =
  FI : { content : 'a content
       ; size : int option
       ; mtime : float option
       ; headers : Headers.t } -> file_info


module type VFS = sig
  val descr : string
  val is_directory : string -> bool
  val contains : string -> bool
  val list_dir : string -> string array
  val delete : string -> unit
  val create : string -> (bytes -> int -> int -> unit) * (unit -> unit)
  val read_file : string -> file_info
end

type vfs = (module VFS)

let vfs_of_dir (top:string) : vfs =
  let module M = struct
    let descr = top
    let (//) = Filename.concat
    let is_directory f = Sys.is_directory (top // f)
    let contains f = Sys.file_exists (top // f)
    let list_dir f = Sys.readdir (top // f)
    let create f =
      let oc = open_out_bin (top // f) in
      let write = output oc in
      let close() = close_out oc in
      write, close
    let delete f = Sys.remove (top // f)
    let read_file f =
      let oc = Unix.openfile (top // f) [O_RDONLY] 0 in
      let stats = Unix.fstat oc in
      let content = Fd(oc) in
      let size = if stats.st_kind = S_REG then
                   Some stats.st_size else None
      in
      let mtime = Some stats.st_mtime in
      let mime =  Magic_mime.lookup f in
      let headers = [(Headers.Content_Type, mime)] in
      FI { content; size; mtime; headers }
  end in
  (module M)

let html_list_dir (module VFS:VFS) ~prefix ~parent d : Html.chaml =
  let entries = VFS.list_dir d in
  Array.sort String.compare entries;

  (* TODO: breadcrumbs for the path, each element a link to the given ancestor dir *)
  let head =
    {html|<head>
            <title>list directory "<?=VFS.descr?>"</title>
            <meta charset="utf-8"/>
          </head>
    |html}
  in
  let n_hidden = ref 0 in
  Array.iter (fun f -> if is_hidden f then incr n_hidden) entries;

  let file_to_elt f : string =
    if not @@ contains_dot_dot (d // f) then (
      let fpath = d // f in
      if not @@ VFS.contains fpath then (
        {html|<li><?= f ?> [invalid file]</li>|html}
      ) else (
        let size =
          try
            match VFS.read_file fpath with
            | FI { size = Some f ; content; _ } ->
               (match content with
                | Fd fd -> Unix.close fd
                | _     -> ());
               Printf.sprintf " (%s)" @@ human_size f
            | _ -> ""
          with _ -> ""
        in
        {html|<li><a href=<?=encode_path ({|/|} // prefix // fpath)?> >
                  <?= f ?></a>
            <?= if VFS.is_directory fpath then " dir" else ""?>
            <?= size ?></li>|html}
      )
    ) else ""
  in
  {chaml|<!DOCTYPE html>
   <html><?=head?>
    <body>
      <h2>Index of "<?= prefix // d ?>"</h2>
      <?ml begin match parent with
         | None -> ()
         | Some p -> echo {html|<a href=<?= encode_path ({|/|} // p) ?>>parent directory</a>|html}
          end;;
      ?>
     <ul>
       <?ml if !n_hidden>0 then
             {funml|<details>(<?= string_of_int !n_hidden ?> hidden files)
                 <?ml Array.iter (fun f -> if is_hidden f then echo (file_to_elt f))
                   entries?>
                 </details>|funml} output;
             Array.iter (fun f -> if not (is_hidden f) then echo (file_to_elt f))
               entries ?>
      </ul>
    </body></html>|chaml}

(* @param on_fs: if true, we assume the file exists on the FS *)
let add_vfs_ ?addresses ?(filter=(fun x -> (x, fun r -> r)))
               ?(config=default_config ())
               ?(prefix="") ~vfs:((module VFS:VFS) as vfs) server : unit=
  let route () =
    if prefix="" then Route.rest
    else let prefix = List.rev (String.split_on_char '/' prefix) in
         List.fold_left (fun acc s -> Route.exact_path s acc) Route.rest prefix
  in
  let check must_exists ope path =
    let path = String.concat "/" path in
    if contains_dot_dot path then (
      log (Exc 0) (fun k->k "%s fails %s (dotdot)" ope path);
      Response.fail_raise ~code:forbidden "Path is forbidden");
    if must_exists && not (VFS.contains path) then Route.pass ();
    path
  in
  if config.delete then (
    Server.add_route_handler ?addresses ~filter ~meth:DELETE
      server (route())
      (fun path -> let path = check true "delete" path in fun _req ->
           Response.make_string
             (try
                log (Req 1) (fun k->k "done delete %s" path);
                VFS.delete path; "file deleted successfully"
              with e ->
                log (Exc 0) (fun k->k "delete fails %s (%s)" path
                                         (Async.printexn e));
                Response.fail_raise ~code:internal_server_error
                  "delete fails: %s (%s)" path (Async.printexn e))
      ))
    else (
      Server.add_route_handler ?addresses ~filter ~meth:DELETE server (route())
        (fun _ _  ->
          Response.fail_raise ~code:method_not_allowed "delete not allowed");
    );

  if config.upload then (
    Server.add_route_handler_stream ?addresses ~meth:PUT server (route())
      ~filter:(fun req ->
          match Request.get_header_int req Headers.Content_Length with
          | Some n when n > config.max_upload_size ->
             Response.fail_raise ~code:forbidden
               "max upload size is %d" config.max_upload_size
          | Some _ when contains_dot_dot req.Request.path ->
             Response.fail_raise ~code:forbidden "invalid path (contains '..')"
          | _ -> filter req
        )
      (fun path -> let path = check false "upload" path in fun req ->
         let write, close =
           try VFS.create path
           with e ->
             log (Exc 0) (fun k->k "fail uploading %s (%s)"
                                      path (Async.printexn e));
             Response.fail_raise ~code:forbidden "cannot upload to %S: %s"
               path (Async.printexn e)
         in
         let req = Request.limit_body_size ~max_size:config.max_upload_size req in
         Input.iter write req.Request.body;
         close ();
         log (Req 1) (fun k->k "done uploading %s" path);
         Response.make_raw ~code:created "upload successful"
      )
  ) else (
    Server.add_route_handler ?addresses ~filter ~meth:PUT server (route())
      (fun _ _  -> Response.make_raw ~code:method_not_allowed
                     "upload not allowed");
  );

  if config.download then (
    Server.add_route_handler ?addresses ~filter ~meth:GET server (route())
      (fun path ->
        let path = check true "download" path in
        fun req ->
        if VFS.is_directory path then
          begin
            match config.dir_behavior with
            | Index | Index_or_lists when
                   VFS.contains (path // "index.html") ->
               let host = match Request.get_header req Headers.Host with
                 | Some h -> h
                 | None -> raise Not_found
               in
               let url = Printf.sprintf "https://%s/%s" host (prefix // path // "index.html") in
               let headers = [ (Headers.Location, url) ] in
               Response.fail_raise ~headers ~code:Response_code.permanent_redirect
                 "Permanent redirect"
            | _ -> ()
          end;
        let FI info = VFS.read_file path in
        let mtime, may_cache =
           match info.mtime with
           | None -> None, false
           | Some t ->
              let mtime_str = Printf.sprintf "\"%.4f\"" t in
              let may_cache =
                match Request.get_header req Headers.If_None_Match with
                | Some mtime -> mtime = mtime_str
                | None ->
                match Request.get_header req Headers.If_Modified_Since with
                | Some str ->
                   (try Util.date_to_epoch str <= t with
                      _ -> false)
                | None -> false
              in
         (Some mtime_str, may_cache)
        in
        if may_cache then
          begin
            (match info.content with
             | Fd fd -> Unix.close fd
             | _ -> ());
            Response.make_raw ~code:not_modified ""
          end
        else
        let cache_control h =
          match mtime with
          | None -> (Headers.Cache_Control, "no-store") :: h
          | Some mtime ->
             (Headers.ETag, mtime)
             :: (Headers.Date, Util.date_of_epoch (Request.start_time req))
             :: (Headers.Cache_Control, "public,no-cache")
             :: h
        in
        if VFS.is_directory path then (
          (match info.content with
          | Fd fd -> Unix.close fd
          | _ -> ());
          let parent = Some (Filename.(dirname (prefix // path))) in
          match config.dir_behavior with
            | Lists | Index_or_lists ->
               let body = html_list_dir ~prefix vfs path ~parent in
               log (Req 1) (fun k->k "download index %s" path);
               let (headers, cookies, str) = body req [header_html] in
               Response.make_stream ~headers ~cookies str
            | Forbidden | Index ->
               Response.make_raw ~code:forbidden "listing dir not allowed"
        ) else (
          let accept_encoding =
            match Request.(get_header req Headers.Accept_Encoding)
            with None -> []
               | Some l -> List.map String.trim (String.split_on_char ',' l)
          in
          let deflate = List.mem "deflate" accept_encoding in
          match info.content with
          | Path(_, Some (fz, size)) when deflate ->
             let fd = Unix.openfile fz [O_RDONLY] 0 in
             Response.make_raw_file
               ~headers:(cache_control
                         ((Headers.Content_Encoding, "deflate")::info.headers))
               ~code:ok size (Util.Sfd.make fd)
          | Path(f, _) ->
             let fd = Unix.openfile f [O_RDONLY] 0 in
             let size = match info.size with Some s -> s | None -> assert false in
             Response.make_raw_file
               ~headers:(cache_control info.headers)
               ~code:ok size (Util.Sfd.make fd)
          | Fd(fd) ->
             let size = Unix.(fstat fd).st_size in
             Response.make_raw_file
               ~headers:(cache_control info.headers)
               ~code:ok size (Util.Sfd.make fd)
          | String(_, Some sz) when deflate ->
             Response.make_raw
               ~headers:(cache_control (
                         (Headers.Content_Encoding, "deflate")::info.headers))
               ~code:ok sz
          | String(s, _) ->
             Response.make_raw
               ~headers:(cache_control info.headers)
               ~code:ok s
          | Dynamic f ->
             let headers = cache_control [] in
             let headers, cookies, input = f req headers in
             Response.make_raw_stream
               ~headers ~cookies ~code:ok input
          | Stream input ->
             Response.make_raw_stream
               ~headers:(cache_control info.headers)
               ~code:ok input

          | Dir _ -> assert false

        )
      )
  ) else (
    Server.add_route_handler ?addresses ~filter ~meth:GET server (route())
      (fun _ _  -> Response.make_raw ~code:method_not_allowed "download not allowed");
  );
  ()

let add_vfs ?addresses ?filter ?prefix ?config ~vfs server : unit =
  add_vfs_ ?addresses ?filter ?prefix ?config ~vfs server

let add_dir_path ?addresses ?filter ?prefix ?config ~dir server : unit =
  add_vfs_ ?addresses ?filter ?prefix ?config ~vfs:(vfs_of_dir dir) server

module Embedded_fs = struct

  type t = {
    emtime: float;
    entries: (string,entry) Hashtbl.t;
    top : string
  }

  and entry = {
      mtime : float option;
      mutable size: int option;
      kind : kind;
      headers: Headers.t
    }

  and kind = t content

  let create ?(top="") ?(mtime=Unix.gettimeofday()) () : t = {
    emtime=mtime;
    entries=Hashtbl.create 128;
    top;
    }

  let split_path_ (path:string) : string list =
    String.split_on_char '/' path

  let add_file_gen (self:t) ~path content : unit =
    let dir_path = split_path_ path in
    if List.mem ".." dir_path then (
      invalid_arg "add_file: '..' is not allowed";
    );

    let rec loop (self:t) dir = match dir with
      | [] -> assert false
      | [basename] ->
         Hashtbl.replace self.entries basename content
      | "." :: ds -> loop self ds
      | d :: ds ->
        let sub =
          match (Hashtbl.find self.entries d).kind with
          | Dir sub -> sub
          | _ ->
            invalid_arg
              (Printf.sprintf "in path %S, %S is a file, not a directory" path d)
          | exception Not_found ->
             let sub = create ~mtime:self.emtime () in
             let entry =
               { kind = Dir sub; mtime = Some self.emtime;
                 size = None; headers = [] }
             in
             Hashtbl.add self.entries d entry;
             sub
        in
        loop sub ds
    in
    loop self dir_path

  let add_file (self:t) ~path ?mtime ?(headers=[]) content : unit =
    let mtime = match mtime with Some t -> t | None -> self.emtime in
    let size = String.length content in
    let sz = Camlzip.deflate_string content in
    let sz =
      if float (String.length sz) > 0.9 *. float size then
        None else Some sz
    in
    let kind = String(content, sz) in
    let entry = { mtime = Some mtime; headers; size = Some size; kind } in
    add_file_gen (self:t) ~path entry

  let add_dynamic (self:t) ~path ?mtime ?(headers=[]) content : unit =
    let entry = { mtime; headers; size = None; kind = Dynamic content} in
    add_file_gen (self:t) ~path entry

  let add_path (self:t) ~path ?mtime ?(headers=[]) ?deflate rpath : unit =
    (*let fz = rpath ^".zlib" in *)
    let deflate = Option.map (fun x ->
                      let size = (Unix.stat x).st_size in
                      x, size) deflate in
    let content = Path(rpath, deflate) in
    let size = Some (Unix.stat rpath).st_size in
    let entry = { mtime; headers; size; kind = content} in
    add_file_gen (self:t) ~path entry

  (* find entry *)
  let find_ self path : entry option =
    let dir_path = split_path_ path in
    let rec loop self dir_name = match dir_name with
      | [] -> assert false
      | [basename] -> (try Some (Hashtbl.find self.entries basename) with _ -> None)
      | "." :: ds -> loop self ds
      | d :: ds ->
        match (Hashtbl.find self.entries d).kind with
        | Dir sub -> loop sub ds
        | _ -> None
        | exception Not_found -> None
    in
    if path="" then Some { mtime = Some self.emtime;
                           size = None;
                           kind = Dir self;
                           headers =[] }
    else loop self dir_path

  let to_vfs self : vfs =
    let module M = struct
      let descr = "Embedded_fs"

      let read_file p =
        match find_ self p with
        | Some { mtime; headers; kind = content; size } ->
           FI { content; mtime; size; headers }
        | _ -> Response.fail_raise ~code:not_found "File %s not found" p

      let contains p = match find_ self p with
        | Some _ -> true
        | None -> false

      let is_directory p = match find_ self p with
        | Some { kind = Dir _; _ } -> true
        | _ -> false

      let list_dir p = match find_ self p with
        | Some { kind = Dir sub; _ } ->
          Hashtbl.fold (fun sub _ acc -> sub::acc) sub.entries [] |> Array.of_list
        | _ -> failwith (Printf.sprintf "no such directory: %S" p)

      let create _ = failwith "Embedded_fs is read-only"
      let delete _ = failwith "Embedded_fs is read-only"

    end in (module M)
end
