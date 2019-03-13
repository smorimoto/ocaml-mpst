include Mpst_base

module Make(X:sig type conn end) = struct
  module Global = Global.Make(X)
  module Session = Global.Session
end

module Global = Global.Make(struct type conn = string Forkpipe.conn end)
module Session = Global.Session
module Forkpipe = Forkpipe
                                 
module Util = struct
  module Global = Global
  open Global
  open Forkpipe


  let msg =
    {select_label=(fun f -> object method msg v=f v end);
     offer_label=(fun (v,c) -> `msg(v,c));
     channel={
         sender=(fun k -> write (fun v -> `msg(v)) k);
         receiver=(fun k -> try_read (function `msg(v) -> Some(v) | _ -> None) k)
    }}
    
  let left =
    {select_label=(fun f -> object method left v=f v end);
     offer_label=(fun (v,c) -> `left(v,c));
     channel={
         sender=(fun k -> write (fun v -> `left(v)) k);
         receiver=(fun k -> try_read (function `left(v) -> Some(v) | _ -> None) k)
    }}

  let right =
    {select_label=(fun f -> object method right v=f v end);
     offer_label=(fun (v,c) -> `right(v,c));
     channel={
         sender=(fun k -> write (fun v -> `right(v)) k);
         receiver=(fun k -> try_read (function `right(v) -> Some(v) | _ -> None) k)
    }}

  let left_or_right =
    {label_merge=(fun ol or_ -> object method left=ol#left method right=or_#right end)}
  let right_or_left =
    {label_merge=(fun ol or_ -> object method left=or_#left method right=ol#right end)}

end
                
