(* open Mpst_base
 * 
 * module Make(F:S.FLAG)(X:sig type conn end) = struct
 *   module Flag = F
 *   
 *   type ('r,'ls) send = Send__
 *   type ('r,'ls) sendmany = SendMany__
 *   type ('r,'ls) receive = Receive__
 *   type ('r,'ls) receivemany = ReceiveMany__
 *   type close
 *           
 *   type conn = X.conn
 * 
 *   module ConnTable : sig
 *     type t
 *     val create : unit -> t
 *     val getone : t -> 'k -> conn
 *     val putone : t -> 'k -> conn -> t
 *     val getmany : t -> 'k -> conn list
 *     val putmany : t -> 'k -> conn list -> t
 *   end = struct
 *     type t = (Obj.t * conn list) list
 *     let create () = []
 *     let putmany t key ks = (Obj.repr key,ks)::t
 *     let getmany t key = List.assoc (Obj.repr key) t
 *     let putone t key k = (Obj.repr key,[k])::t
 *     let getone t key =
 *       match List.assoc (Obj.repr key) t with
 *       | [] -> raise Not_found
 *       | [x] -> x
 *       | _ -> failwith "ConnTable: multiplicity mismatch"
 *   end
 * 
 *   type _ prot =
 *     | Send :
 *         'r * (ConnTable.t -> 'ls)
 *         -> ('r, 'ls) send prot
 *     | SendMany :
 *         'r * (ConnTable.t -> conn(\* a small hack *\)  -> 'ls) (\* TODO explain why we have this extra conn parameter *\)
 *         -> ('r, 'ls) sendmany prot
 *     | Receive :
 *         'r * (ConnTable.t -> 'ls Lwt.t) list
 *         -> ('r, 'ls) receive prot
 *     | ReceiveMany :
 *         'r * ((ConnTable.t -> 'ls Lwt.t) list)
 *         -> ('r, 'ls) receivemany prot
 *     | Close : close prot
 *     | DummyReceive :
 *         ('r, 'ls) receive prot
 *     
 *   type 'p sess =
 *     {once:Flag.t; conn:ConnTable.t; prot:'p prot}
 * 
 *   let send : 'r 'ls 'v 's.
 *              ([>] as 'r) ->
 *              ((< .. > as 'ls) -> 'v -> 's sess) ->
 *              'v ->
 *              ('r, 'ls) send sess ->
 *              's sess =
 *     fun _ sel v {once;conn;prot=Send (_,f)} ->
 *     Flag.use once;
 *     let s = sel (f conn) v in
 *     s
 * 
 *   let multicast : 'r 'ls 'v 's.
 *                   ([>] as 'r) ->
 *                   ((< .. > as 'ls) -> 'v -> 's sess) ->
 *                   (int -> 'v) ->
 *                   ('r, 'ls) sendmany sess ->
 *                   's sess =
 *     fun _ sel f {once;conn;prot=SendMany (r,ls)} ->
 *     Flag.use once;
 *     match List.mapi (fun i k -> sel (ls conn k) (f i)) (ConnTable.getmany conn r) with
 *     | [] -> failwith "no connection"
 *     | s::_ -> s
 *   
 *   let rec first k = function
 *     | [] -> Lwt.fail (Failure "receive failed")
 *     | f::fs ->
 *        Lwt.catch (fun () -> f k) (function
 *            | ReceiveFail -> first k fs
 *            | e -> Lwt.fail e)
 *       
 *   let receive : 'r 'ls.
 *                 ([>] as 'r) ->
 *                 ('r, 'ls) receive sess -> 'ls Lwt.t =
 *     fun _ {once;conn;prot=s} ->
 *     Flag.use once;
 *     match s with
 *     | Receive(_, fs) ->
 *        first conn fs
 *     | DummyReceive ->
 *        failwith "Session: DummyReceive encountered" 
 * 
 *   let gather : 'r 'ls.
 *                ([>] as 'r) ->
 *                ('r, 'ls) receivemany sess -> 'ls Lwt.t =
 *     fun _ {once;conn;prot=ReceiveMany(_,f)} ->
 *     Flag.use once;
 *     first conn f
 * 
 *   let close {once;conn;prot=Close} = Flag.use once
 * 
 *   module Internal = struct
 *     
 *     let merge : type t. t prot -> t prot -> t prot = fun x y ->
 *       match x, y with
 *       | Send _, Send _ ->
 *          raise RoleNotEnabled
 *       | SendMany _, SendMany _ ->
 *          raise RoleNotEnabled
 *       | Receive (r, xs), Receive (_, ys) ->
 *          Receive (r, xs @ ys)
 *       | ReceiveMany (r, xs), ReceiveMany (_, ys) ->
 *          ReceiveMany (r, xs @ ys)
 *       | Receive (r, xs), DummyReceive ->
 *          Receive (r, xs)
 *       | DummyReceive, Receive (r, xs) ->
 *          Receive (r, xs)
 *       | DummyReceive, DummyReceive ->
 *          DummyReceive
 *       | Close, Close ->
 *          Close
 *   end
 * end *)
