(** {1 Static directory serving and page generation} *)

(** Some tools, like url encoding *)
module Util : sig
  (** {1 Some utils for writing web servers}

      @since 0.2
   *)

  val percent_encode : ?skip:(char -> bool) -> string -> string
  (** Encode the string into a valid path following
      https://tools.ietf.org/html/rfc3986#section-2.1
      @param skip if provided, allows to preserve some characters, e.g. '/' in a path.
   *)

  val percent_decode : string -> string
  (** Inverse operation of {!percent_encode}.
      Can raise [Invalid_argument "percent_decode"] if string is not valid
      percent encodings. *)

  val pp_date : Format.formatter -> Unix.tm -> unit
  (** Print date (given in GMT) in the expected format for http (for instance
      for expiration date of cookies.
      @since 0.12
   *)

  val split_query : string -> string * string
  (** Split a path between the path and the query
      @since 0.5 *)

  val split_on_slash : string -> string list
  (** Split a string on ['/'], remove the trailing ['/'] if any.
      @since 0.6 *)

  val get_non_query_path : string -> string
  (** get the part of the path that is not the query parameters.
      @since 0.5 *)

  val get_query : string -> string
  (** Obtain the query part of a path.
      @since 0.4 *)

  val parse_query : string -> ((string*string) list, string) result
  (** Parse a query as a list of ['&'] or [';'] separated [key=value] pairs.
      The order might not be preserved.
      @since 0.3
   *)
end

module Input : sig
  (** Input streams are used to represent a series of bytes that can arrive
    progressively.  For example, an uploaded file will be sent as a series of
    chunks and also for output streams. *)

  type hidden
  type t = {
      mutable bs: bytes;
      (** The bytes *)

      mutable off : int;
      (** Beginning of valid slice in {!bs} *)

      mutable len : int;
      (** Length of valid slice in {!bs}. If [len = 0] after
          a call to {!fill_buf}, then the stream is finished. *)

      fill_buf: unit -> unit;
      (** See the current slice of the internal buffer as [bytes, i, len],
          where the slice is [bytes[i] .. [bytes[i+len-1]]].
          Can block to refill the buffer if there is currently no content.
          If [len=0] then there is no more data. *)

      consume: int -> unit;
      (** Consume [n] bytes from the buffer.
          This should only be called with [n <= len]. *)

      close: unit -> unit;
      (** Close the stream. *)

      _rest: hidden;
      (** Use {!make} to build a stream. *)
    }
  (** A buffered stream, with a view into the current buffer (or refill if empty),
      and a function to consume [n] bytes. *)


  val close : t -> unit
  (** Close stream *)

  val empty : t
  (** Stream with 0 bytes inside *)

  val make :
    ?bs:bytes ->
    ?close:(t -> unit) ->
    consume:(t -> int -> unit) ->
    fill:(t -> unit) ->
    unit -> t
  (** [make ~fill ()] creates a byte stream.
      @param fill is used to refill the buffer, and is called initially.
      @param close optional closing.
      @param init_size size of the buffer.
   *)

  val of_chan : ?buf_size:int -> in_channel -> t
  (** Make a buffered stream from the given channel. *)

  val of_fd : ?buf_size:int -> Unix.file_descr -> t
  (** Make a buffered stream from the given file descriptor. *)

  val of_client : ?buf_size:int -> Async.client -> t
  (** Make a buffered stream from the given http client. *)

  val of_client_fd : ?buf_size:int -> Async.Io.t -> t
  (** Allow a to Make a buffered stream from the given descriptor.
      The call will be scheduled if read blocks. *)

  val of_bytes : ?i:int -> ?len:int -> bytes -> t
  (** A stream that just returns the slice of bytes starting from [i]
      and of length [len]. *)

  val of_string : string -> t

  val iter : (bytes -> int -> int -> unit) -> t -> unit
  (** Iterate on the chunks of the stream. *)

  val to_chan : out_channel -> t -> unit
  (** Write the stream to the channel. *)

  val with_file : ?buf_size:int -> string -> (t -> 'a) -> 'a
  (** Open a file with given name, and obtain an input stream
      on its content. When the function returns, the stream (and file) are closed. *)

  val read_char : t -> char

  val read_line : buf:Buffer.t -> t -> string
  (** Read a line from the stream.
      @param buf a buffer to (re)use. Its content will be cleared. *)

  val read_all : buf:Buffer.t -> t -> string
  (** Read the whole stream into a string.
      @param buf a buffer to (re)use. Its content will be cleared. *)

  val read_until : buf:Buffer.t -> target:string -> t -> unit
  (** Advance in the stream until in meet the given target.
      @param buf a buffer to (re)use. Its content will be cleared. *)

  val read_exactly :
    close_rec:bool -> size:int -> too_short:(int -> unit) ->
    t -> t
  (** [read_exactly ~size bs] returns a new stream that reads exactly
      [size] bytes from [bs], and then closes.
      @param close_rec if true, closing the resulting stream also closes
        [bs]
        @param too_short is called if [bs] closes with still [n] bytes remaining
   *)
end

module Output : sig
  (** Module holding the response stream for a client request. We cannot use
      out_channel, because we need our own write function. You should not need
      to use it directly. *)

  (** Type of output stream *)
  type t

  (** Flush the output *)
  val flush : t -> unit

  (** Close the channel connection *)
  val close : t -> unit

  (** Add a charactere *)

  val add_char : t -> char -> unit

  (** Add an integer in decimal representation *)
  val add_decimal : t -> int -> unit

  (** Add an integer in hexadecimal representation *)
  val add_hexa : t -> int -> unit

  (** Add a string *)
  val add_string : t -> string -> unit

  (** Add a sybstring *)
  val add_substring : t -> string -> int -> int -> unit

  (** Add a byte sequence *)
  val add_bytes : t -> bytes -> unit

  (** Add a subbyte sequance *)
  val add_subbytes : t -> bytes -> int -> int -> unit

  (** Like [Printf.printf] *)
  val printf : t -> ('a, unit, string, unit) format4 -> 'a

  val sendfile: t -> int -> Unix.file_descr -> unit
  (** Try to send n bytes from the given file descriptor using sendfile linux
      system call. Note: the descriptor can be use by several thread as its
      internal offset is not updated. *)
end

module Address : sig
  (** Module for declaring address and port to listen to *)

  (** A type to index all listened addresses *)
  type index = private int

  (** Record type storing the an address we listen on *)
  type t =
    private
      { addr : string  (** The actual address in formal "0.0.0.0" *)
      ; port : int     (** The port *)
      ; ssl  : Ssl.context option (** An optional ssl context *)
      ; reuse : bool   (** Can we reuse the socket *)
      ; mutable index : index (** The index used to refer to the address *)
      }

  (** The constructor to build an address *)
  val make : ?addr:string -> ?port:int -> ?ssl:Ssl.context ->
             ?reuse:bool -> unit -> t
end

module Async : sig
  (** {1 Cooperative threading} *)

  (** The following functions deals with cooperative multi-tasking on each
      domain.  First, recall {!Simple_httpd} will choose the domain with the
      least number of clients to serve a new client, and after that, it is
      impossible for a job to change domain. This is a current limitation of
      domain with OCaml 5.0.

      Then, on each domain, priority is based on arrival time: first arrived,
      first to run.

      Normally context switching occurs when read or write is blocked or when a
      mutex is already locked, with one exception: {!yield} is called after each
      request treatment if the client uses [keepalive] connection.
   *)


  (** General functions related to OCaml's domain and asynchrone cooperative
    multithreading. *)

  (** Vocabulary:
      - socket: a file descriptor: may be the connection socket or another ressource
      like a connection to a database, a file etc.
      - client: a connection to the server. Each client has at least one socket (the
      connection socket)
      - session: an application can do several connections to the server and
      be identified as one session using session cookies.
   *)


  (** Connection status. Holds the number of clients per domain.  *)
  type status = {
      nb_connections : int Atomic.t array
    }

  val string_status : status -> string

  (** Record describing clients *)
  type client

  val yield : unit -> unit
  (** let other thread run. Should be called for treatment that take time
      before sending results or reading data and when the other primitives
      can not be used. This happends typically for a pure computing task.
      Other solutions exists for instance for database request.
   *)

  val sleep : float -> unit
  (** Same as above, but with a minimum sleeping time in second *)

  val close : client -> unit
  (** Close the given client connection *)

  val flush : client -> unit
  (** Flushes clients output *)

  (** Module with function similar to Unix.read and Unix.single_write
    but that will perform scheduling instead of blocking. This can be used to
    access your database. It has been tested with OCaml's bindings to [libpq]. *)
  module type Io = sig
    type t

    val create : Unix.file_descr -> t
    val close : t -> unit
    val read : t -> Bytes.t -> int -> int -> int
    val write : t -> Bytes.t -> int -> int -> int
  end

  (** [schedule_io sock action] should be called when a non blocking read/write
      operation would have blocked. When read become possible, [action ()] will
      be called.  The return value should be (if possible) the number of bytes
      read or written. It this is meaningless, return a non zero value if some
      progress was made, while returning 0 will terminates the management of the
      client.

      A typical application for this is when interacting with a data base in non
      blocking mode. For just reading a socket, use the Io module above.
   *)
  val schedule_io : Unix.file_descr -> (unit -> int) -> int

  (**/**)
  (** internal use for qtest **)
  val fake_client : client
  (**/**)
end

module type Io = Async.Io

module Io : Io

module Log : sig
  (** Server Logging facility *)
  val set_log_lvl : int -> unit
  val set_log_folder : ?basename:string -> ?perm:int -> string -> int -> unit
  val f : ?lvl:int ->
          ((('a, out_channel, unit, unit) format4 -> 'a) -> unit) -> unit
end

module Mutex : sig
  (** Simple_httpd notion of mutex. You must be careful with server wide mutex:
      a DoS attack could try to hold such a mutex. A mutex per session may be a good
      idea. A mutex per client is useless (client are treated sequentially).

      FIXME: there is a global mutex for file cache. It is holded very shortly
      and once the file is in the cache it is not used anymore, so this is OK,
      but still if could be a target of attack ?

      Note: they are implemented using Linux [eventfd] *)
  type t

  val create : unit -> t
  val try_lock : t -> bool
  val lock : t -> unit
  val unlock : t -> unit
end

module Response_code : sig
  (** {1 Response Codes}

    Response code allows client to know if a request failed and give a reason.
    This module is not complete (yet). *)

  type t = int
  (** A standard HTTP code.

      https://tools.ietf.org/html/rfc7231#section-6 *)

  val ok : t
  (** The code [200] *)

  val not_found : t
  (** The code [404] *)

  val descr : t -> string
  (** A description of some of the error codes.
      NOTE: this is not complete (yet). *)

  (** A function raising an exception with an error code and a string response *)
  val bad_reqf : t -> ('a, unit, string, 'b) format4 -> 'a
end

module Method : sig
  (** {1 Methods}

      A short module defining the various HTTP methods (GET,PUT,...)*)

  type t =
    | GET
    | PUT
    | POST
    | HEAD
    | DELETE
  (** A HTTP method.
      For now we only handle a subset of these.

      See https://tools.ietf.org/html/rfc7231#section-4 *)

  val pp : Format.formatter -> t -> unit
  val to_string : t -> string
  val of_string : string -> t
end

module Headers : sig
  (** {1 Headers}

    Headers are metadata associated with a request or response. This module provide
    the necessary function to read and modify headers *)

(** A module defining all the legal header names *)

  (** @inline *)
  include module type of Headers_

  type t = (header * string) list
  (** The header files of a request or response.

      Neither the key nor the value can contain ['\r'] or ['\n'].
      See https://tools.ietf.org/html/rfc7230#section-3.2 *)

  val empty : t
  (** Empty list of headers *)

  val get : ?f:(string->string) -> header -> t -> string option
  (** [get k headers] looks for the header field with key [k].
      @param f if provided, will transform the value before it is returned. *)

  val get_exn : ?f:(string->string) -> header -> t -> string
  (** [get_exn k headers] same as above but raise [Not_found] if the headers is
      not present. *)

  val set : header -> string -> t -> t
  (** [set k v headers] sets the key [k] to value [v].
      It erases any previous entry for [k] *)

  val set_cookies : Cookies.t -> t -> t
  (** Encode all the cookies in the header *)

  val remove : header -> t -> t
  (** Remove the key from the headers, if present. *)

  val contains : header -> t -> bool
  (** Is there a header with the given key? *)

  val pp : Format.formatter -> t -> unit
  (** Pretty print the headers. *)
end

module Cookies : sig
  (** {1 Cookies}

    Cookies are data that are maintend both on server and clients.
    This is a module to get and set cookies in the headers. *)

  type t = (string * Http_cookie.t) list

  val empty : t
  val parse : string -> t
  val add : string -> Http_cookie.t -> t -> t
  val create : ?path:string ->
               ?domain:string ->
               ?expires:Http_cookie.date_time ->
               ?max_age:int64 ->
               ?secure:bool ->
               ?http_only:bool ->
               ?same_site:Http_cookie.same_site ->
               ?extension:string ->
               name:string ->
               string -> t -> t

  val get : string -> t -> Http_cookie.t

  (** remove a cookie by setting a negative max-age. Does nothing
      if there are no cookie with that name. *)
  val delete : string -> t -> t

  (** remove all cookies by setting a negative max-age *)
  val delete_all : t -> t
end

module Request : sig
  (** {1 Requests}

      Requests are sent by a client, e.g. a web browser, curl or wget. *)

  type 'body t
  (** A request with method, path, host, headers, and a body, sent by a client.

      The body is polymorphic because the request goes through several
      transformations. First it a body with a unread {!Simple_httpd.Input.t}
      stream, as only the request and headers are read; while the body might
      be entirely read as a string via {!read_body_full}.  *)

  val pp : Format.formatter -> string t -> unit
  (** Pretty print the request and its body *)

  val headers : _ t -> Headers.t
  (** List of headers of the request, including ["Host"] *)

  val get_header : ?f:(string->string) -> _ t -> Headers.header -> string option

  val get_header_int : _ t -> Headers.header -> int option

  val set_header : Headers.header -> string -> 'a t -> 'a t
  (** [set_header k v req] sets [k: v] in the request [req]'s headers. *)

  val update_headers : (Headers.t -> Headers.t) -> 'a t -> 'a t
  (** Modify headers *)

  val body : 'b t -> 'b
  (** Request body, possibly empty. *)

  val set_body : 'a -> _ t -> 'a t
  (** [set_body b req] returns a new query whose body is [b]. *)

  val cookies : _ t -> Cookies.t
  (** List of cookies of the request *)

  val get_cookie : _ t -> string -> Http_cookie.t option
  (** get a cookie *)

  val host : _ t -> string
  (** Host field of the request. It also appears in the headers. *)

  val meth : _ t -> Method.t
  (** Method for the request. *)

  val path : _ t -> string
  (** Request path. *)

  val client : _ t -> Async.client
  (** Request client *)

  val query : _ t -> (string*string) list
  (** Decode the query part of the {!field-path} field *)

  val start_time : _ t -> float
  (** time stamp (from [Unix.gettimeofday]) after parsing the first line of
    the request *)

  val trailer : _ t -> (Headers.t * Cookies.t) option
  (** trailer, read after a chunked body. Only maeningfull after the body stream
      we fully read and closed *)

  val close_after_req : _ t -> bool
  (** Tells if we are supposed to close the connection after answering the request *)

  val read_body_full : buf:Buffer.t -> Input.t t -> string t
  (** Read the whole body into a string. *)

  (**/**)
  (** internals, for qtest *)
  val parse_req_start :  client:Async.client -> buf:Buffer.t ->
                         Input.t -> Input.t t option
  val parse_body : buf:Buffer.t -> Input.t t -> Input.t t
  (**/**)
end

module Response : sig
  (** {1 Responses}

      Responses are what a http server, such as {!Simple_httpd}, send back to
      the client to answer a {!Request.t}*)

  type body = String of string
            | Stream of Input.t
            | File of int * Unix.file_descr * bool
            | Void
  (** Body of a response, either as a simple string,
      or a stream of bytes, or nothing (for server-sent events). *)

  type t
  (** A response to send back to a client. *)

  val body : t -> body
  (** Get the body of the response *)

  val set_body : body -> t -> t
  (** Set the body of the response. *)

  val set_header : Headers.header -> string -> t -> t
  (** Set a header. *)

  val update_headers : (Headers.t -> Headers.t) -> t -> t
  (** Modify headers *)

  val set_headers : Headers.t -> t -> t
  (** Set all headers. *)

  val headers : t -> Headers.t
  (** Get headers *)

  val set_code : Response_code.t -> t -> t
  (** Set the response code. *)

  val make_raw :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    code:Response_code.t ->
    string ->
    t
  (** Make a response from its raw components, with a string body.
      Use [""] to not send a body at all. *)

  val make_raw_stream :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    code:Response_code.t ->
    Input.t ->
  t
  (** Same as {!make_raw} but with a stream body. The body will be sent with
      the chunked transfer-encoding. *)

  val make_raw_file :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    code:Response_code.t ->
    close:bool ->
    int -> Unix.file_descr ->
    t
  (** Same as {!make_raw} but with a file_descriptor. The body will be sent with
      Linux sendfile system call.
      @param [close] tells if one must close the file_descriptor after sending
        the response.
   *)

  val make :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    body -> t
  (** [make r] turns a body into a response.

      - [make (Ok body)] replies with [200] and the body.
      - [make (Error (code,msg))] replies with the given error code
      and message as body.
   *)

  val make_void :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    code:int -> unit -> t

  val make_string :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    string -> t
  (** Same as {!make} but with a string body. *)

  val make_stream :
    ?cookies:Cookies.t ->
    ?headers:Headers.t ->
    Input.t -> t
  (** Same as {!make} but with a stream body. *)

  val make_file :
    ?cookies:Cookies.t ->
    ?headers:Headers.t -> close:bool ->
    int -> Unix.file_descr -> t
  (** Same as {!make} but with a file_descr body. *)

  val fail :
    ?cookies:Cookies.t ->
    ?headers:Headers.t -> code:int ->
    ('a, unit, string, t) format4 -> 'a
  (** Make the current request fail with the given code and message.
      Example: [fail ~code:404 "oh noes, %s not found" "waldo"].
   *)

  val fail_raise : code:int -> ('a, unit, string, 'b) format4 -> 'a
  (** Similar to {!fail} but raises an exception that exits the current handler.
      This should not be used outside of a (path) handler.
      Example: [fail_raise ~code:404 "oh noes, %s not found" "waldo"; never_executed()]
   *)

  val pp : Format.formatter -> t -> unit
  (** Pretty print the response. *)
end

module Route : sig
  (** {1 Routing}

      Basic type-safe routing. *)

  type ('a, 'b) comp
  type ('a, 'b) t
  (** A route, composed of path components *)

  val int : (int -> 'a, 'a) comp
  (** Matches an integer. *)

  val string : (string -> 'a, 'a) comp
  (** Matches a string not containing ['/'] and binds it as is. *)

  val exact : string -> ('a, 'a) comp
  (** [exact "s"] matches ["s"] and nothing else. *)

  val return : ('a, 'a) t
  (** Matches the empty path. *)

  val rest : (string list -> 'a, 'a) t
  (** Matches a string, even containing ['/']. This will match
      the entirety of the remaining route. *)

  val (@/) : ('a, 'b) comp -> ('b, 'c) t -> ('a, 'c) t
  (** [comp / route] matches ["foo/bar/…"] iff [comp] matches ["foo"],
      and [route] matches ["bar/…"]. *)

  val exact_path : string -> ('a,'b) t -> ('a,'b) t
  (** [exact_path "foo/bar/..." r] is equivalent to
      [exact "foo" @/ exact "bar" @/ ... @/ r] **)

  val pp : Format.formatter -> _ t -> unit
  (** Print the route. 0.7 *)

  val to_string : _ t -> string
  (** Print the route. 0.7 *)

  (** {1 Filters} *)

  (** Type of request filters. These filters may transform both the request and
      the response. Several method may share filter passed as optional parameters
      to function like {!add_route_handler}.

      The transformation of the response may depend on the request, Hence the
      type. For instance the filter provided by the optional module
      {{:../../simple_httpd_camlzip/Simple_httpd_camlzip/index.html}Simple_httpd_camlzip} uses this to compress the
      response only if [deflate] is allowed using the header named
    {!Headers.Accept_Encoding}. *)

  type filter = Input.t Request.t -> Input.t Request.t * (Response.t -> Response.t)

  val decode_request : (Input.t -> Input.t) -> (Headers.t -> Headers.t)
                       -> filter
  (** helper to create a filter transforming only the request. *)

  val encode_response : (Response.body -> Response.body) -> (Headers.t -> Headers.t)
                        -> filter
  (** helper to create a filter transforming only the resposne. *)

  val compose_embrace : filter -> filter -> filter
  (** [compose_embrace f1 f2] compose two filters:
      the request will be passed first to [f2], then to [f1],
      the response will be passed first to [f2], then to [f1] **)

  val compose_cross : filter -> filter -> filter
  (** [compose_cross f1 f2] compose two filters:
      the request will be passed first to [f2], then to [f1],
      the response will be passed first to [f1], then to [f2] **)
end

module Session : sig
  (** This module allows to mange session which are common to several client
      and can survive a deconnection of the clients. This do not provide
      any form of authentication, but it is easy to use them to implement
      authentication. *)

  type session
  type session_data

  val check : ?session_life_time:float ->
              ?init:(unit -> session_data) ->
              ?check:(session -> bool) ->
              ?error:(int*string) ->
              Route.filter

  val do_session_data : (session_data -> 'a) -> session -> 'a

  val set_session_data : session -> session_data -> (session_data -> unit) -> unit

  val set_session_cookie : session -> string -> string -> unit

  (** remove all server side session data *)
  val delete_session : session -> unit
end

module Html : sig
  (** HTML combinators.

      This module provides combinators to produce html. It doesn't enforce
      the well-formedness of the html, unlike Tyxml, but it's simple and should
      be reasonably efficient.
   *)

  (** @inline *)
  include module type of Html_

  (** Convert a HTML element to a string.
    @param top if true, add DOCTYPE at the beginning. The top element should then
    be a "html" tag. *)
  val to_string : ?top:bool -> elt -> string

  (** Convert a list of HTML elements to a string.
    This is designed for fragments of HTML that are to be injected inside
    a bigger context, as it's invalid to have multiple elements at the toplevel
    of a HTML document. *)
  val to_string_l : elt list -> string

  val to_stream : elt -> Input.t
end

module Server : sig
  (** {1 Main Server type} *)

  type t
  (** A HTTP server. See {!create} for more details. *)

  val create :
    ?masksigpipe:bool ->
    ?max_connections:int ->
    ?num_thread:int ->
    ?timeout:float ->
    ?buf_size:int ->
    ?listens:Address.t list ->
    unit ->
    t
  (** Create a new webserver.

      The server will not do anything until {!run} is called on it. Before starting the server, one can use {!add_route_handler} to specify how to handle incoming requests.

      @param masksigpipe if true, block the signal [Sys.sigpipe] which otherwise tends to kill client threads when they try to write on broken sockets. Default: [true].
      @param buf_size size for buffers (since 0.11)
      @param max_connections maximum number of simultaneous connections.
      @param num_thread number of thread to treat client.
      @param timeout connection is closed if the socket does not do read or
        write for the amount of second. Default: 300s, (< 0.0 means no timeout).
        timeout is not recommended when using proxy.
        @param addr address (IPv4 or IPv6) to listen on. Default ["127.0.0.1"].
        @param port to listen on. Default [8080].
        @param sock an existing socket given to the server to listen on, e.g. by
          systemd on Linux (or launchd on macOS). If passed in, this socket will be
          used instead of the [addr] and [port]. If not passed in, those will be
          used. This parameter exists since 0.10.
   *)

  val listens : t -> Address.t array
  (** Addresses and ports on which the server listens. *)

  val status : t -> Async.status
  (** Returns server status *)

  val active_connections : t -> int
  (** Number of active connections *)

  (** {1 Route handlers}

      Here are the main function to explain what you server should to depending
      on the url send by the client.
   *)

  val add_route_handler :
    ?addresses:Address.t list ->
    ?hostnames:string list ->
    ?meth:Method.t ->
    ?filter:Route.filter ->
    t ->
    ('a, string Request.t -> Response.t) Route.t -> 'a ->
    unit
  (** [add_route_handler server route f] add a route to give a [string] as
      response.

      For instance, [add_route_handler serverRoute.(exact "path" @/ string @/
      int @/ return) f] calls [f "foo" 42 request] when a [request] with path
      "path/foo/42/" is received.

      Note that the handlers are called in the following precision order:
      - {!Route.return}, accepting only the empty url is the most precide
      - [{!Route.exact} s], is the second, tried
      - {!Route.int}
      - {!Route.string}
      - {!Route.rest} is tried last.
      - In case of ambiguity, the first added route is tried first.

      @param adresses if provided, only accept requests from the given
        adress and port. Will raise
        [Invalid_argument "add_route: the server is not listening to that adress"]
        if the server is not listenning to that adresse and port.
        @param meth if provided, only accept requests with the given method.
          Typically one could react to [`GET] or [`PUT].
          @param filter can be used to modify the request and response and also
            to reject some request using {!Response.fail_raise}. The default filter
            accept all requests and does not do any transformation.
   *)

  val add_route_handler_stream :
    ?addresses:Address.t list ->
    ?hostnames:string list ->
    ?meth:Method.t ->
    ?filter:Route.filter ->
    t ->
    ('a, Input.t Request.t -> Response.t) Route.t -> 'a ->
    unit
  (** Similar to {!add_route_handler}, but where the body of the request
      is a stream of bytes that has not been read yet.
      This is useful when one wants to stream the body directly into a parser,
      json decoder (such as [Jsonm]) or into a file. *)

  (** {1 Server-sent events}

      {b EXPERIMENTAL}: this API is not stable yet. *)

  (** A server-side function to generate of Server-sent events.

      See {{: https://html.spec.whatwg.org/multipage/server-sent-events.html} the w3c page}
      and {{: https://jvns.ca/blog/2021/01/12/day-36--server-sent-events-are-cool--and-a-fun-bug/}
      this blog post}.
   *)
  module type SERVER_SENT_GENERATOR = sig
    val set_headers : Headers.t -> unit
    (** Set headers of the response.
        This is not mandatory but if used at all, it must be called before
        any call to {!send_event} (once events are sent the response is
        already sent too). *)

    val send_event :
      ?event:string ->
      ?id:string ->
      ?retry:string ->
      data:string ->
      unit -> unit
    (** Send an event from the server.
        If data is a multiline string, it will be sent on separate "data:" lines. *)

    val close : unit -> unit
                          (** Close connection. *)
  end

  type server_sent_generator = (module SERVER_SENT_GENERATOR)
  (** Server-sent event generator *)

  val add_route_server_sent_handler :
    ?filter:Route.filter ->
    t ->
    ('a, string Request.t -> server_sent_generator -> unit) Route.t -> 'a ->
    unit
  (** Add a handler on an endpoint, that serves server-sent events.

      The callback is given a generator that can be used to send events
      as it pleases. The connection is always closed by the client,
      and the accepted method is always [GET].
      This will set the header "content-type" to "text/event-stream" automatically
      and reply with a 200 immediately.
      See {!server_sent_generator} for more details.

      This handler stays on the original thread (it is synchronous). *)

  (** {1 Run the server} *)

  val run : t -> unit
  (** Run the main loop of the server, listening on a socket
      described at the server's creation time. *)

end

module Dir : sig
  (** Serving static content from directories

    This module provides the same functionality as the "http_of_dir" tool.
    It exposes a directory (and its subdirectories), with the optional ability
    to delete or upload files. *)

  (** behavior of static directory.

      This controls what happens when the user requests the path to
      a directory rather than a file. *)
  type dir_behavior =
    | Index
    (** Redirect to index.html if present, else fails. *)
    | Lists
    (** Lists content of directory. Be careful of security implications. *)
    | Index_or_lists
    (** Redirect to index.html if present and lists content otherwise.
        This is useful for tilde ("~") directories and other per-user behavior,
        but be mindful of security implications *)
    | Forbidden
  (** Forbid access to directory. This is suited for serving assets, for example. *)

  (** Static files can be cached/served in various ways *)
  type cache = NoCache  (** No cache: serve directly the file from its location *)
             | MemCache (** Cache a string in memory *)
             | CompressCache of string * (string -> string)
             (** Cache a compressed string in memory. The first parameter
                 must be the Transfer-Encoding name of the compression algorithme
                 and the second argument is the compression function *)
             | SendFile
             (** Require to use sendfile linux system call. Faster, but
                 useless with SSL. *)
             | SendFileCache
             (** Cache a file descriptor to be used with sendfile linux system
                 call. It you indent to serve thousand of simultaneous
                 connection, [SendFile] or [NoCache] will require one socket per
                 connection while [SendFileCache] will use one socket per static
                 file. *)

  (** type of the function deciding which cache policy to use *)
  type choose_cache = size:int option -> mime:string -> accept_encoding:string list
                      -> cache

  (** configuration for static file handlers. This might get
      more fields over time. *)
  type config = {
      mutable download: bool;
      (** Is downloading files allowed? *)

      mutable dir_behavior: dir_behavior;
      (** Behavior when serving a directory and not a file *)

      mutable delete: bool;
      (** Is deleting a file allowed? (with method DELETE) *)

      mutable upload: bool;
      (** Is uploading a file allowed? (with method PUT) *)

      mutable max_upload_size: int;
      (** If {!upload} is true, this is the maximum size in bytes for
          uploaded files. *)

      mutable cache: choose_cache;
      (** Cache download of file. *)
    }

  (** default configuration: [
      { download=true
      ; dir_behavior=Forbidden
      ; delete=false
      ; upload=false
      ; max_upload_size = 10 * 1024 * 1024
      ; cache=false
      }] *)
  val default_config : unit -> config

  val config :
    ?download:bool ->
    ?dir_behavior:dir_behavior ->
    ?delete:bool ->
    ?upload:bool ->
    ?max_upload_size:int ->
    ?cache:choose_cache ->
    unit ->
    config
  (** Build a config from {!default_config}. *)

  (** [add_dirpath ~config ~dir ~prefix server] adds route handle to the
      [server] to serve static files in [dir] when url starts with [prefix],
      using the given configuration [config]. *)
  val add_dir_path :
    ?addresses: Address.t list ->
    ?hostnames: string list ->
    ?filter:Route.filter ->
    ?prefix:string ->
    ?config:config ->
    dir:string ->
    Server.t -> unit

  (** Virtual file system.

      This is used to emulate a file system from pure OCaml functions and data,
      e.g. for resources bundled inside the web server.

      Remark: the diffrence between VFS and cache is that caches are updated
      when the modification time of the file changes. Thus, VFS do not do any
      system call.
   *)
  module type VFS = sig
    val descr : string
    (** Description of the VFS *)

    val is_directory : string -> bool

    val contains : string -> bool
    (** [file_exists vfs path] returns [true] if [path] points to a file
        or directory inside [vfs]. *)

    val list_dir : string -> string array
    (** List directory. This only returns basenames, the files need
        to be put in the directory path using [Filename.concat]. *)

    val delete : string -> unit
    (** Delete path *)

    val create : string -> (bytes -> int -> int -> unit) * (unit -> unit)
    (** Create a file and obtain a pair [write, close] *)

    val read_file_content : string -> string
    (** Read content of a file *)

    val read_file_stream : string -> Input.t
    (** Read content of a file as a stream *)

    val read_file_fd : string -> int * Unix.file_descr
    (** Read content of a file as a size and file_descriptor *)

    val file_size : string -> int option
    (** File size, e.g. using "stat" *)

    val file_mtime : string -> float option
    (** File modification time, e.g. using "stat" *)
  end

  val vfs_of_dir : string -> (module VFS)
  (** [vfs_of_dir dir] makes a virtual file system that reads from the
      disk.
   *)

  val add_vfs :
    ?addresses: Address.t list ->
    ?hostnames: string list ->
    ?filter:Route.filter ->
    ?prefix:string ->
    ?config:config ->
    vfs:(module VFS) ->
    Server.t -> unit
  (** Similar to {!add_dir_path} but using a virtual file system instead.
   *)

  (** An embedded file system, as a list of files with (relative) paths.
      This is useful in combination with the "simple-httpd-mkfs" tool,
      which embeds the files it's given into a OCaml module.
   *)
  module Embedded_fs : sig
    type t
    (** The pseudo-filesystem *)

    val create : ?mtime:float -> unit -> t

    val add_file : ?mtime:float -> t -> path:string -> string -> unit
    (** Add file to the virtual file system.
        @raise Invalid_argument if the path contains '..' or if it tries to
          make a directory out of an existing path that is a file. *)

    val to_vfs : t -> (module VFS)
  end
end

module Host : sig
  open Server
  open Dir

  module type HostInit = sig
    val server : t

    val add_route_handler :
      ?meth:Method.t ->
      ?filter:Route.filter ->
      ('a, string Request.t -> Response.t) Route.t -> 'a -> unit

    val add_route_handler_stream :
      ?meth:Method.t ->
      ?filter:Route.filter ->
      ('a, Input.t Request.t -> Response.t) Route.t -> 'a -> unit

    val add_dir_path :
      ?filter:Route.filter ->
      ?prefix:string ->
      ?config:config ->
      string -> unit

    val add_vfs :
      ?filter:Route.filter ->
      ?prefix:string ->
      ?config:config ->
      (module VFS) -> unit
  end

  module type Host = sig
    val addresses : Address.t list
    val hostnames : string list

    module Init(_:HostInit) : sig end
  end

  val start_server :
    ?masksigpipe:bool ->
    ?max_connections:int ->
    ?num_thread:int ->
    ?timeout:float ->
    ?buf_size:int -> (module Host) list -> unit
end
