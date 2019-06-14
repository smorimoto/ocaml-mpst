
let map_option f = function
  | Some x -> Some (f x)
  | None -> None

let rec find_physeq : 'a. 'a list -> 'a -> bool = fun xs y ->
  match xs with
  | x::xs -> if x==y then true else find_physeq xs y
  | [] -> false

type ('lr, 'l, 'r) obj_merge =
  {obj_merge: 'l -> 'r -> 'lr;
   obj_splitL: 'lr -> 'l;
   obj_splitR: 'lr -> 'r;
  }

type ('la,'va) method_ =
  {make_obj: 'va -> 'la;
   call_obj: 'la -> 'va}


(*
 * A mergeable is a session endpoint which can be merged with another endpoint in future.
 * It is a function of type ('a option -> 'a) which returns (1) the merged endpoint when
 * another endpoint (Some ep) is passed, or (2) the endpoint itself when the argument is None.
 * 
 * Mergeables enable endpoints to be merged based on the object structure.
 * In ocaml-mpst, endpoints are nested objects (and events).
 * The problem is that, in OCaml type system, one can not inspect the object structure 
 * when its type is not known.
 * A mergeble is a bundle of an endpoint and its merging strategy, providing a way 
 * to merge two endpoints of the same type into one.
 *
 * Mergeables themselves can be merged with other mergeables.
 * Specifically, `Mergeable.merge_delayed` will return a "delayed" mergeable which is 
 * used to merge recursive endpoints.
 * A delayed mergeable are forced when `resolve_merge` is called.
 *
 * In ocaml-mpst, `resolve_merge` is called during "get_ep" phase to ensure that the all
 * mergings are resolved before actual communication will take place.
 *)
module Mergeable
  = struct
  type 'a t =
    | M of 'a u
    | MDelayMerge of 'a u list
  and 'a u =
    | Val of ('a option -> 'a)
    | Var of 'a t lazy_t

  exception UnguardedLoop

  let make mrg v =
    M (Val (function
        | None -> v
        | Some v2 -> mrg v v2))

  let make_with_hook hook mrg v1 =
    M (Val (function
        | None -> (hook v1 : unit); v1
        | Some v2 -> let v12 = mrg v1 v2 in hook v12; v12))

  type 'a merge__ = 'a option -> 'a

  let merge0 : type x. x merge__ -> x merge__ -> x merge__ = fun l r ->
    fun obj -> l (Some (r obj))

  let merge : 'a. 'a t -> 'a t -> 'a t =
    fun l r ->
    match l, r with
    | M (Val ll), M (Val rr) ->
       M (Val (merge0 ll rr))
    | M v1, M v2 ->
       MDelayMerge [v1; v2]
    | M v, MDelayMerge ds | MDelayMerge ds, M v ->
       MDelayMerge (v :: ds)
    | MDelayMerge d1, MDelayMerge d2 ->
       MDelayMerge (d1 @ d2)

  let merge_all = function
    | [] -> failwith "merge_all: empty"
    | m::ms -> List.fold_left merge m ms
             
  let no_merge : 'a. 'a -> 'a t  = fun v ->
    M (Val (fun _ -> v))
    
  let bare_ : 'a. ('a option -> 'a) -> 'a t  = fun v ->
    M (Val v)

  let rec out__ : type x. x t lazy_t list -> x t -> x option -> x =
    fun hist t ->
    let resolve d =
      if find_physeq hist d then
        raise UnguardedLoop
      else
        out__ (d::hist) (Lazy.force d)
    in
    match t with
    | M (Val x) -> x
    | M (Var d) ->
       resolve d
    | MDelayMerge ds ->
       let solved =
         List.fold_left (fun acc d ->
             match d with
             | Val v -> v :: acc
             | Var d ->
                try
                  resolve d :: acc
                with
                  UnguardedLoop -> acc)
           [] ds
       in
       match solved with
       | [] ->
          raise UnguardedLoop
       | x::xs ->
          List.fold_left merge0 x xs

  let out_ : 'a. 'a t -> 'a = fun g ->
    out__ [] g None

  let out : 'a. 'a t -> 'a option -> 'a = fun g ->
    out__ [] g

  (* 
   * resolve_merge: try to resolve choices which involve recursion variables.
   * calls to this function from (-->) combinator is delayed until get_ep phase
   * (i.e. after evaluating global combinators)
   *)
  let resolve_merge : 'a. 'a t -> unit = fun t ->
    match t with
    | M (Val _) ->
       () (* already evaluated *)
    | M (Var _) ->
       () (* do not touch -- this is a recursion variable *)
    | MDelayMerge _ ->
       (* try to resolve it -- a choice involving recursion variable(s) *)
       let _ = out__ [] t in ()

  let rec applybody : 'a 'b. ('a -> 'b) u -> 'a -> 'b u = fun f v ->
    match f with
    | Var d ->
       Var (lazy (apply (Lazy.force d) v))
    | Val f ->
       Val (fun othr ->
           match othr with
           | Some othr -> f (Some (fun _ -> othr)) v (* XXX *)
           | None -> f None v)
      
  and apply : 'a 'b. ('a -> 'b) t -> 'a -> 'b t = fun f v ->
    match f with
    | MDelayMerge(ds) ->
       MDelayMerge(List.map (fun d -> applybody d v) ds)
    | M f -> M (applybody f v)

  let rec obj_raw = fun meth f ->
    function
    | None ->
       meth.make_obj (f None)
    | Some o ->
       meth.make_obj (f (Some (meth.call_obj o)))
                           
  let rec obj : 'v. (< .. > as 'o, 'v) method_ -> 'v t -> 'o t = fun meth v ->
    match v with
    | M (Val f) ->
       M (Val (obj_raw meth f))
    | M (Var d) ->
       M (Var (lazy (obj meth (Lazy.force d))))
    | MDelayMerge ds ->
       MDelayMerge (List.map
                     (function
                      | Val f -> Val (obj_raw meth f)
                      | Var d -> Var (lazy (obj meth (Lazy.force d)))) ds)

  let objfun
      : 'o 'v 'p. ('v -> 'v -> 'v) -> (< .. > as 'o, 'v) method_ -> ('p -> 'v) -> ('p -> 'o) t =
    fun merge meth val_ ->
    bare_ (fun obj p ->
        match obj with
        | None ->
           meth.make_obj (val_ p)
        | Some obj ->
           let val2 = meth.call_obj (obj p) in
           meth.make_obj (merge (val_ p) val2))
end

(*
 * The module for the sequence of endpoints.
 * 
 *)
module Seq = struct
  type _ t =
    | S : 'a u -> 'a t
    | SDelayMerge : 'a u list -> 'a t
    | SBottom : 'x t
  and _ u =
    | SeqCons : 'hd Mergeable.t * 'tl t -> [`cons of 'hd * 'tl] u
    | SeqVar : 'x t lazy_t -> 'x u
    | SeqRepeat : 'a Mergeable.t -> ([`cons of 'a * 'tl] as 'tl) u

  type (_,_,_,_) lens =
    | Zero  : ('hd0, 'hd1, [`cons of 'hd0 * 'tl] t, [`cons of 'hd1 * 'tl] t) lens
    | Succ : ('a, 'b, 'tl0 t, 'tl1 t) lens
             -> ('a,'b, [`cons of 'hd * 'tl0] t, [`cons of 'hd * 'tl1] t) lens

  exception UnguardedLoopSeq
          
  let rec seq_head : type hd tl. [`cons of hd * tl] t -> hd Mergeable.t =
    function
    | S u -> seqbody_head u
    | SDelayMerge ds -> Mergeable.merge_all (List.map seqbody_head ds)
    | SBottom -> raise UnguardedLoopSeq
  and seqbody_head : type hd tl. [`cons of hd * tl] u -> hd Mergeable.t =
    function
    | SeqCons(hd,_) -> hd
    | SeqRepeat(a) -> a
    | SeqVar d -> Mergeable.M (Var (lazy (seq_head (Lazy.force d))))

  let rec seq_tail : type hd tl. [`cons of hd * tl] t -> tl t =
    function
    | S u -> seqbody_tail u
    | SDelayMerge ds -> SDelayMerge(List.flatten (List.map decomp (List.map seqbody_tail ds)))
    | SBottom -> raise UnguardedLoopSeq
  and seqbody_tail : type hd tl. [`cons of hd * tl] u -> tl t =
    function
    | SeqCons(_,tl) -> tl
    | (SeqRepeat _) as s -> S s
    | SeqVar d -> S(SeqVar(lazy (seq_tail (Lazy.force d))))
  and decomp : type x. x t -> x u list = function
    | S u -> [u]
    | SDelayMerge ds -> ds
    | SBottom -> raise UnguardedLoopSeq

  let rec get : type a b xs ys. (a, b, xs, ys) lens -> xs -> a Mergeable.t = fun ln xs ->
    match ln with
    | Zero -> seq_head xs
    | Succ ln' -> get ln' (seq_tail xs)

  let rec put : type a b xs ys. (a,b,xs,ys) lens -> xs -> b Mergeable.t -> ys =
    fun ln xs b ->
    match ln with
    | Zero -> S(SeqCons(b, seq_tail xs))
    | Succ ln' -> S(SeqCons(seq_head xs, put ln' (seq_tail xs) b))

  let rec seq_merge : type x. x t -> x t -> x t = fun l r ->
    match l,r with
    | S(SeqCons(_,_)), _ ->
       let hd = Mergeable.merge (seq_head l) (seq_head r) in
       let tl = seq_merge (seq_tail l) (seq_tail r) in
       S(SeqCons(hd, tl))
    | _, S(SeqCons(_,_)) ->
       seq_merge r l
    (* delayed constructors left as-is *)
    | S((SeqVar _) as u1), S((SeqVar _) as u2) -> SDelayMerge [u1; u2]
    | SDelayMerge(us), S((SeqVar _) as u) -> SDelayMerge(u::us)
    | S((SeqVar _) as u), SDelayMerge(us) -> SDelayMerge(u::us)
    | SDelayMerge(us1), SDelayMerge(us2) -> SDelayMerge(us1 @ us2)
    (* repeat *)
    | S(SeqRepeat(a)), _ -> S(SeqRepeat(a))
    | _, S(SeqRepeat(a)) -> S(SeqRepeat(a))
    (* bottom *)
    | SBottom,_  -> raise UnguardedLoopSeq
    | _, SBottom -> raise UnguardedLoopSeq

  let rec resolve_delayed_ : type x. x t lazy_t list -> x t lazy_t -> x t =
    fun hist w ->
    if find_physeq hist w then begin
        raise UnguardedLoopSeq
      end else begin
        match Lazy.force w with
        | S (SeqVar w') -> resolve_delayed_ (w::hist) w'
        | s -> s
      end

  (*
   * partial_force:
   * it tries to expand unguarded recursion variables which occurs right under the
   * fixpoint combinator. This enables a "fail-fast" policy to handle unguarded recursions --
   * it would raise an exception if there is an unguarded occurrence of a recursion variable.
   * This fuction is called during the initial construction phase of an 
   * endpoint sequence.
   *)
  let rec partial_force : type x. x t lazy_t list -> x t -> x t =
    fun hist ->
    function
    | S(SeqVar d) ->
       (* recursion variable -- try to expand it *)
       partial_force [] (resolve_delayed_ [] d)
    | S(SeqCons(hd,tl)) ->
       let tl =
         try
           partial_force [] tl (* FIXME use (map seq_tail hist) ? *)
         with
           UnguardedLoopSeq -> SBottom
       in
       S(SeqCons(hd, tl))
    | S(SeqRepeat(_)) as xs -> xs
    | SDelayMerge ds ->
       (* A choice with recursion variables -- do not try to resolve.
        * Mergeable.resolve_merge will resolve it later during get_ep
        *)
       SDelayMerge ds
    | SBottom -> SBottom
end
  
let fix : type t. (t Seq.t -> t Seq.t) -> t Seq.t = fun f ->
  let rec body =
    lazy begin
        f (S(SeqVar body))
      end
  in
  (* A "fail-fast" approach to detect unguarded loops.
   * Seq.partial_force tres to fully evaluate unguarded recursion variables 
   * in the body.
   *)
  Seq.partial_force [body] (Lazy.force body)

type ('robj,'c,'a,'b,'xs,'ys) role =
  {label:('robj,'c) method_;
   lens:('a,'b,'xs,'ys) Seq.lens}

type close = Close

let get_ep r g =
  let ep = Seq.get r.lens g in
  Mergeable.out_ ep

let a = {label={make_obj=(fun v->object method role_A=v end);
                call_obj=(fun o->o#role_A)};
         lens=Zero}
let b = {label={make_obj=(fun v->object method role_B=v end);
                call_obj=(fun o->o#role_B)};
         lens=Succ Zero}
let c = {label={make_obj=(fun v->object method role_C=v end);
                call_obj=(fun o->o#role_C)};
         lens=Succ (Succ Zero)}
let d = {label={make_obj=(fun v->object method role_D=v end);
                call_obj=(fun o->o#role_D)};
         lens=Succ (Succ (Succ Zero))}

module type LIN = sig
  type 'a lin
  val mklin : 'a -> 'a lin
  val unlin : 'a lin -> 'a
end

module type EVENT = sig
  type 'a event
  val guard : (unit -> 'a event) -> 'a event
  val choose : 'a event list -> 'a event
  val wrap : 'a event -> ('a -> 'b) -> 'b event
end
module LwtEvent = struct
  type 'a event = 'a Lwt.t
  let guard f = f () (*XXX correct??*)
  let choose = Lwt.choose
  let wrap e f = Lwt.map f e
end

type ('la,'lb,'va,'vb) label =
  {obj: ('la, 'va) method_;
   var: 'vb -> 'lb}

let msg =
  {obj={make_obj=(fun f -> object method msg=f end);
        call_obj=(fun o -> o#msg)};
   var=(fun v -> `msg(v))}
let left =
  {obj={make_obj=(fun f -> object method left=f end);
        call_obj=(fun o -> o#left)};
   var=(fun v -> `left(v))}
let right =
  {obj={make_obj=(fun f -> object method right=f end);
        call_obj=(fun o -> o#right)};
   var=(fun v -> `right(v))}
let middle =
  {obj={make_obj=(fun f -> object method middle=f end);
        call_obj=(fun o -> o#middle)};
   var=(fun v -> `middle(v))}
  
let left_or_right =
  {obj_merge=(fun l r -> object method left=l#left method right=r#right end);
   obj_splitL=(fun lr -> (lr :> <left : _>));
   obj_splitR=(fun lr -> (lr :> <right : _>));
  }
let right_or_left =
  {obj_merge=(fun l r -> object method right=l#right method left=r#left end);
   obj_splitL=(fun lr -> (lr :> <right : _>));
   obj_splitR=(fun lr -> (lr :> <left : _>));
  }
let to_b m =
  {obj_merge=(fun l r -> object method role_B=m.obj_merge l#role_B r#role_B end);
   obj_splitL=(fun lr -> object method role_B=m.obj_splitL lr#role_B end);
   obj_splitR=(fun lr -> object method role_B=m.obj_splitR lr#role_B end);
  }
let b_or_c =
  {obj_merge=(fun l r -> object method role_B=l#role_B method role_C=r#role_C end);
   obj_splitL=(fun lr -> (lr :> <role_B : _>));
   obj_splitR=(fun lr -> (lr :> <role_C : _>));
  }
