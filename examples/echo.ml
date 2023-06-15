
open Simple_httpd
module H = Headers

let now = Unix.gettimeofday

(** add a missing [add_float] function to Atomic *)
module Atomic = struct
  include Atomic
  let add_float a x =
    let fn () =
      let v = Atomic.get a in
      Atomic.compare_and_set a v (v +. x)
    in
    while not (fn ()) do () done;
end

(** [Simple_httpd] provides filter for request, that can be used to collecting
    statistics. Currently, we can not cound the time to output the response. *)
let filter_stat () : Route.filter * (unit -> string) =
  (* We must use atomic for this to work with domains! *)
  let nb_req     = Atomic.make 0  in
  let total_time = Atomic.make 0. in
  let parse_time = Atomic.make 0. in
  let build_time = Atomic.make 0. in

  let measure req =
    Atomic.incr nb_req;
    let t1 = Request.start_time req in
    let t2 = now () in
    (req, fun response ->
        let t3 = now () in
        Atomic.add_float total_time (t3 -. t1);
        Atomic.add_float parse_time (t2 -. t1);
        Atomic.add_float build_time (t3 -. t2);
        response)
  and get_stat () =
    let nb = Atomic.get nb_req in
    Printf.sprintf "%d requests (average response time: %.3fms = %.3fms + %.3fms)"
      nb (Atomic.get total_time /. float nb *. 1e3)
         (Atomic.get parse_time /. float nb *. 1e3)
         (Atomic.get build_time /. float nb *. 1e3)
  in
  (measure, get_stat)

(** default address, port and maximum number of connections *)
let addr = ref "127.0.0.1"
let port = ref 8080
let j = ref 32

(** parse command line option *)
let _ =
  Arg.parse (Arg.align [
      "--addr", Arg.Set_string addr, " set address";
      "-a", Arg.Set_string addr, " set address";
      "--port", Arg.Set_int port, " set port";
      "-p", Arg.Set_int port, " set port";
      "--log", Arg.Int (fun n -> Log.set_log_lvl n), " set debug lvl";
      "-j", Arg.Set_int j, " maximum number of connections";
    ]) (fun _ -> raise (Arg.Bad "")) "echo [option]*"

(** Server initialisation *)
let listens = [Address.make ~addr:!addr ~port:!port ()]
let server = Server.create ~listens ~max_connections:!j ()

(** Compose the above filter with the compression filter
    provided by [Simple_httpd_camlzip] *)
let filter, get_stats =
  let filter_stat, get_stats = filter_stat () in
  let filter_zip =
    Simple_httpd_camlzip.filter ~compress_above:1024 ~buf_size:(16*1024) () in
  (Route.compose_cross filter_zip filter_stat, get_stats)

(** Add a route answering 'Hello' *)
let _ =
  Server.add_route_handler ~meth:GET server ~filter
    Route.(exact "hello" @/ string @/ return)
    (fun name _req -> Response.make_string ("hello " ^name ^"!\n"))

(** Add a route sending a compressed stream for the given file in the current
    directory *)
let _ =
  Server.add_route_handler ~meth:GET server
    Route.(exact "zcat" @/ string @/ return)
    (fun path _req ->
        let ic = open_in path in
        let str = Input.of_chan ic in
        let mime_type =
          try
            let p = Unix.open_process_in (Printf.sprintf "file -i -b %S" path) in
            try
              let s = [H.Content_Type, String.trim (input_line p)] in
              ignore @@ Unix.close_process_in p;
              s
            with _ -> ignore @@ Unix.close_process_in p; []
          with _ -> []
        in
        Response.make_stream ~headers:mime_type str
      )

(** Add an echo request *)
let _ =
  Server.add_route_handler server
    Route.(exact "echo" @/ return)
    (fun req ->
      let q =
        Request.query req |> List.map (fun (k,v) -> Printf.sprintf "%S = %S" k v)
        |> String.concat ";"
      in
      Response.make_string
        (Format.asprintf "echo:@ %a@ (query: %s)@." Request.pp req q))

(** Add file upload *)
let _ =
  Server.add_route_handler_stream ~meth:PUT server
    Route.(exact "upload" @/ string @/ return)
    (fun path req ->
        Log.f (fun k->k "start upload %S, headers:\n%s\n\n%!" path
                     (Format.asprintf "%a" Headers.pp (Request.headers req)));
        try
          let oc = open_out @@ "/tmp/" ^ path in
          Input.to_chan oc (Request.body req);
          flush oc;
          Response.make_string "uploaded file"
        with e ->
          Response.fail ~code:500 "couldn't upload file: %s" (Printexc.to_string e)
      )

(** Access to the statistics *)
let _ =
  Server.add_route_handler server Route.(exact "stats" @/ return)
    (fun _req ->
       let stats = get_stats() in
       Response.make_string stats
    )

(** Add a virtual file system VFS, produced by [simple-httpd-vfs-pack] from
    an actual folger *)
let _ =
  Dir.add_vfs server
    ~config:(Dir.config ~download:true
               ~dir_behavior:Dir.Index_or_lists ())
    ~vfs:Vfs.vfs ~prefix:"vfs"

(** Main pagen using the Html module*)
let _ =
  Server.add_route_handler server Route.return
    (fun _req ->
       let open Html in
       let h = html [] [
           head[][title[][txt "index of echo"]];
           body[][
             h3[] [txt "welcome!"];
             p[] [b[] [txt "endpoints are:"]];
             ul[] [
               li[][pre[][txt "/hello/:name (GET)"]];
               li[][pre[][a[A.href "/echo/"][txt "echo"]; txt " echo back query"]];
               li[][pre[][txt "/upload/:path (PUT) to upload a file"]];
               li[][pre[][txt "/zcat/:path (GET) to download a file (deflate transfer-encoding)"]];
               li[][pre[][a[A.href "/stats/"][txt"/stats/"]; txt" (GET) to access statistics"]];
               li[][pre[][a[A.href "/vfs/"][txt"/vfs"]; txt" (GET) to access a VFS embedded in the binary"]];
             ]
           ]
         ] in
       let s = to_string ~top:true h in
       Response.make_string ~headers:[H.Content_Type, "text/html"] s)

(** Output a message before starting the server *)
let _ =
  Array.iter (fun l ->
    let open Address in
    Printf.printf "listening on http://%s:%d\n%!" l.addr l.port) (Server.listens server)

(** Start the server *)
let _ =
  Server.run server
