open Printf
open Unix
open Util
open Daemon

module type ARRANGEMENT = sig
  type name
  type state
  type input
  type output
  type msg
  type client_id
  type res = (output list * state) * ((name * msg) list)
  type task_handler = name -> state -> res
  type timeout_setter = name -> state -> float
  val systemName : string
  val serializeName : name -> string
  val deserializeName : string -> name option
  val init : name -> state
  val handleIO : name -> input -> state -> res
  val handleNet : name -> name -> msg -> state -> res
  val deserializeMsg : string -> msg
  val serializeMsg : msg -> string
  val deserializeInput : string -> client_id -> input option
  val serializeOutput : output -> client_id * string
  val debug : bool
  val debugInput : state -> input -> unit
  val debugRecv : state -> (name * msg) -> unit
  val debugSend : state -> (name * msg) -> unit
  val createClientId : unit -> client_id
  val serializeClientId : client_id -> string
  val timeoutTasks : (task_handler * timeout_setter) list
end

module Shim (A: ARRANGEMENT) = struct
  type cfg =
      { cluster : (A.name * (string * int)) list
      ; me : A.name
      ; port : int
      }

  type env =
      { cfg : cfg
      ; nodes_fd : file_descr
      ; clients_fd : file_descr
      ; nodes : (A.name * sockaddr) list
      ; client_read_fds : (file_descr, A.client_id) Hashtbl.t
      ; client_write_fds : (A.client_id, file_descr) Hashtbl.t
      ; tasks : (file_descr, (env, A.state) task) Hashtbl.t
      }

  exception Disconnect of string

  (* Translate node name to UDP socket address. *)
  let denote_node (env : env) (name : A.name) : sockaddr =
    List.assoc name env.nodes

  (* Translate UDP socket address to node name. *)
  let undenote_node (env : env) (addr : sockaddr) : A.name =
    let flip = function (x, y) -> (y, x) in
    List.assoc addr (List.map flip env.nodes)

  (* Translate client id to TCP socket address *)
  let denote_client (env : env) (c : A.client_id) : file_descr =
    Hashtbl.find env.client_write_fds c

  (* Translate TCP socket address to client id *)
  let undenote_client (env : env) (fd : file_descr) : A.client_id =
    Hashtbl.find env.client_read_fds fd

  (* Gets initial state from the arrangement *)
  let get_initial_state (cfg : cfg) : A.state =
    A.init cfg.me

  (* Initialize environment *)
  let setup (cfg : cfg) : (env * A.state) =
    let addressify (name, (host, port)) =
      let entry = gethostbyname host in
      (name, ADDR_INET (Array.get entry.h_addr_list 0, port))
    in
    Random.self_init ();
    let env =
      { cfg = cfg
      ; nodes_fd = socket PF_INET SOCK_DGRAM 0
      ; clients_fd = socket PF_INET SOCK_STREAM 0
      ; nodes = List.map addressify cfg.cluster
      ; client_read_fds = Hashtbl.create 17
      ; client_write_fds = Hashtbl.create 17
      ; tasks = Hashtbl.create 17
      }
    in
    let initial_state = get_initial_state cfg in
    let (host, port) = List.assoc cfg.me cfg.cluster in
    let entry = gethostbyname host in
    let listen_addr = Array.get entry.h_addr_list 0 in
    setsockopt env.clients_fd SO_REUSEADDR true;
    setsockopt env.nodes_fd SO_REUSEADDR true;
    bind env.nodes_fd (ADDR_INET (listen_addr, port));
    bind env.clients_fd (ADDR_INET (inet_addr_any, cfg.port));
    listen env.clients_fd 8;
    (env, initial_state)

  (* throws Unix_error, Disconnect *)
  let send_chunk (fd : file_descr) (buf : bytes) : unit =
    let len = Bytes.length buf in
    let n = Unix.send fd (raw_bytes_of_int len) 0 4 [] in
    if n < 4 then raise (Disconnect "send_chunk: message header failed to send all at once");
    let n = Unix.send fd buf 0 len [] in
    if n < len then raise (Disconnect (sprintf "send_chunk: message of length %d failed to send all at once" len))
  
  (* throws Unix_error, Disconnect *)
  let receive_chunk env (fd : file_descr) : bytes =
    let receive_check fd buf offs len flags =
      let n = Unix.recv fd buf offs len flags in
      if n = 0 then raise (Disconnect "receive_chunk: other side closed connection");
      n
    in
    let buf4 = Bytes.make 4 '\x00' in
    let n = receive_check fd buf4 0 4 [] in
    if n < 4 then raise (Disconnect "receive_chunk: message header did not arrive all at once");
    let len = int_of_raw_bytes buf4 in
    let buf = Bytes.make len '\x00' in
    let n = receive_check fd buf 0 len [] in
    if n < len then raise (Disconnect (sprintf "receive_chunk: message of length %d did not arrive all at once" len));
    buf

  let schedule_finalize_task t =
    t.select_on <- false;
    t.wake_time <- Some 0.5;
    t.process_read <- (fun t env state -> (true, [], state));
    t.process_wake <- (fun t env state -> (true, [], state))

  (* throws nothing *)
  let output env o =
    let (c, out) = A.serializeOutput o in
    try send_chunk (denote_client env c) out
    with
    | Not_found ->
      eprintf "output: failed to find socket for client %s" (A.serializeClientId c);
      prerr_newline ()
    | Disconnect s ->
      eprintf "output: failed send to client %s: %s" (A.serializeClientId c) s;
      prerr_newline ();
      schedule_finalize_task (Hashtbl.find env.tasks (denote_client env c))
    | Unix_error (err, fn, _) ->
      eprintf "output: error %s" (error_message err);
      prerr_newline ();
      schedule_finalize_task (Hashtbl.find env.tasks (denote_client env c))

  (* throws Unix_error *)
  let new_client_conn env =
    let (client_fd, client_addr) = accept env.clients_fd in
    let c = A.createClientId () in
    Hashtbl.replace env.client_read_fds client_fd c;
    Hashtbl.replace env.client_write_fds c client_fd;
    if A.debug then begin
      printf "[%s] client %s connected on %s" (timestamp ()) (A.serializeClientId c) (string_of_sockaddr client_addr);
      print_newline ()
    end;
    client_fd

  let sendto sock buf addr =
    try
      ignore (Unix.sendto sock buf 0 (String.length buf) [] addr)
    with Unix_error (err, fn, arg) ->
      printf "error in sendto: %s, dropping message" (error_message err);
      print_newline ()

  let send env ((nm : A.name), (msg : A.msg)) =
    sendto env.nodes_fd (A.serializeMsg msg) (denote_node env nm)

  let respond env ((os, s), ps) =
    List.iter (output env) os;
    List.iter (fun p -> if A.debug then A.debugSend s p; send env p) ps;
    s

  (* throws Disconnect, Unix_error *)
  let input_step (env : env) (fd : file_descr) (state : A.state) =
    let buf = receive_chunk env fd in
    let c = undenote_client env fd in
    match A.deserializeInput buf c with
    | Some inp ->
      let state' = respond env (A.handleIO env.cfg.me inp state) in
      if A.debug then A.debugInput state' inp;
      state'
    | None ->
      raise (Disconnect (sprintf "input_step: could not deserialize %s" buf))

  (* throws Unix_error *)
  let recv_step (env : env) (fd : file_descr) (state : A.state) : A.state =
    let len = 65536 in
    let buf = Bytes.make len '\x00' in
    let (_, from) = recvfrom fd buf 0 len [] in
    let (src, msg) = (undenote_node env from, A.deserializeMsg buf) in
    let state' = respond env (A.handleNet env.cfg.me src msg state) in
    if A.debug then A.debugRecv state' (src, msg);
    state'  

  let node_read_task env =
    { fd = env.nodes_fd
    ; select_on = true
    ; wake_time = None
    ; process_read =
	(fun t env state ->
	  try
	    let state' = recv_step env t.fd state in
	    (false, [], state')
	  with Unix_error (err, fn, _) ->
	    eprintf "error receiving message from node in %s: %s" fn (error_message err);
	    prerr_newline ();
	    (false, [], state))
    ; process_wake = (fun t env state -> (false, [], state))
    ; finalize = (fun t env state -> Unix.close t.fd; state)
    }

  let client_read_task fd =
    { fd = fd
    ; select_on = true
    ; wake_time = None
    ; process_read =
	(fun t env state ->
	  try
	    let state' = input_step env t.fd state in
	    (false, [], state')
	  with 
	  | Disconnect s ->
	    eprintf "connection error for client %s: %s" (A.serializeClientId (undenote_client env t.fd)) s;
	    prerr_newline ();
	    (true, [], state)
	  | Unix_error (err, fn, _) ->
	    eprintf "error for client %s: %s" (A.serializeClientId (undenote_client env t.fd)) (error_message err);
	    prerr_newline ();
	    (true, [], state))
    ; process_wake = (fun t env state -> (false, [], state))
    ; finalize =
	(fun t env state ->
	  let client_fd = t.fd in
	  let c = undenote_client env client_fd in
	  if A.debug then begin
	    printf "[%s] closing connection to client %s" (timestamp ()) (A.serializeClientId c);
	    print_newline ();
	  end;
	  Hashtbl.remove env.client_read_fds client_fd;
	  Hashtbl.remove env.client_write_fds c;
	  Unix.close client_fd;
	  state)
    }

  let client_connections_task env =
    { fd = env.clients_fd
    ; select_on = true
    ; wake_time = None
    ; process_read =
	(fun t env state ->
	  try
	    let client_fd = new_client_conn env in
	    (false, [client_read_task client_fd], state)
	  with Unix_error (err, fn, _) ->
	    eprintf "incoming client connection error in %s: %s" fn (error_message err);
	    prerr_newline ();
	    (false, [], state))
    ; process_wake = (fun t env state -> (false, [], state))
    ; finalize = (fun t env state -> Unix.close t.fd; state)
    }

  let timeout_task env curr_state handler setter =
    { fd = Unix.dup env.clients_fd
    ; select_on = false
    ; wake_time = Some (setter env.cfg.me curr_state)
    ; process_read = (fun t env state -> (false, [], state))
    ; process_wake =
	(fun t env state ->
	  let state' = respond env (handler env.cfg.me state) in
	  t.wake_time <- Some (setter env.cfg.me state');
	  (false, [], state'))
    ; finalize = (fun t env state -> Unix.close t.fd; state)
    }

  let main (cfg : cfg) : unit =
    printf "daemonized unordered shim running setup for %s" A.systemName;
    print_newline ();
    let (env, initial_state) = setup cfg in
    let t_nd_conn = node_read_task env in
    let t_cl_conn = client_connections_task env in
    Hashtbl.add env.tasks t_nd_conn.fd t_nd_conn;
    Hashtbl.add env.tasks t_cl_conn.fd t_cl_conn;
    List.iter (fun (h, s) ->
      let t = timeout_task env initial_state h s in
      Hashtbl.add env.tasks t.fd t) A.timeoutTasks;
    printf "daemonized unordered shim ready for %s" A.systemName;
    print_newline ();
    eloop 2.0 (Unix.gettimeofday ()) env.tasks env initial_state
end