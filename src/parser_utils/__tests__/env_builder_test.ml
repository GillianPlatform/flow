(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Test_utils
module LocMap = Loc_collections.LocMap
module LocSet = Loc_collections.LocSet

let mk_ssa_builder_test contents expected_values ctxt =
  let refined_reads = Env_builder.With_Loc.program (parse contents) in
  let printer locmap =
    let kvlist = LocMap.bindings locmap in
    let strlist =
      Base.List.map
        ~f:(fun (read_loc, refinement) ->
          Printf.sprintf
            "%s => { %s }"
            (Loc.debug_to_string read_loc)
            (Env_builder.show_refinement refinement))
        kvlist
    in
    Printf.sprintf "[ %s ]" (String.concat "; " strlist)
  in
  assert_equal
    ~ctxt
    ~cmp:(eq printer)
    ~printer
    ~msg:"SSA values don't match!"
    expected_values
    refined_reads

let mk_write (pos1, pos2) = Ssa_api.Write (mk_loc pos1 pos2)

let tests =
  let open Env_builder in
  "env_builder"
  >::: [
         "logical_expr"
         >:: mk_ssa_builder_test
               "let x = null;
let y = null;
(x && (y = x)) + x"
               LocMap.(empty |> add (mk_loc (3, 11) (3, 12)) Truthy);
         "logical_expr_successive"
         >:: mk_ssa_builder_test
               "let x = null;
x && (x && x)"
               LocMap.(
                 empty
                 |> add (mk_loc (2, 6) (2, 7)) Truthy
                 |> add (mk_loc (2, 11) (2, 12)) (And (Truthy, Truthy)));
         "logical_or"
         >:: mk_ssa_builder_test
               "let x = null;
x || x"
               LocMap.(empty |> add (mk_loc (2, 5) (2, 6)) (Not Truthy));
         "logical_nested_right"
         >:: mk_ssa_builder_test
               "let x = null;
x || (x || x)"
               LocMap.(
                 empty
                 |> add (mk_loc (2, 6) (2, 7)) (Not Truthy)
                 |> add (mk_loc (2, 11) (2, 12)) (And (Not Truthy, Not Truthy)));
         "logical_nested"
         >:: mk_ssa_builder_test
               "let x = null;
(x || x) && x"
               LocMap.(
                 empty
                 |> add (mk_loc (2, 6) (2, 7)) (Not Truthy)
                 |> add (mk_loc (2, 12) (2, 13)) (Or (Truthy, Truthy)));
         "logical_nested2"
         >:: mk_ssa_builder_test
               "let x = null;
(x && x) || (x && x)"
               LocMap.(
                 empty
                 |> add (mk_loc (2, 6) (2, 7)) Truthy
                 |> add (mk_loc (2, 13) (2, 14)) (Not (And (Truthy, Truthy)))
                 |> add (mk_loc (2, 18) (2, 19)) (And (Not (And (Truthy, Truthy)), Truthy)));
         "assignment_truthy"
         >:: mk_ssa_builder_test
               "let x = null;
(x = null) && x"
               LocMap.(empty |> add (mk_loc (2, 14) (2, 15)) Truthy);
         "eq_null"
         >:: mk_ssa_builder_test
               "let x = null;
(x == null) && x"
               LocMap.(empty |> add (mk_loc (2, 15) (2, 16)) Maybe);
         "neq_null"
         >:: mk_ssa_builder_test
               "let x = null;
(x != null) && x"
               LocMap.(empty |> add (mk_loc (2, 15) (2, 16)) (Not Maybe));
         "strict_eq_null"
         >:: mk_ssa_builder_test
               "let x = null;
(x === null) && x"
               LocMap.(empty |> add (mk_loc (2, 16) (2, 17)) Null);
         "strit_neq_null"
         >:: mk_ssa_builder_test
               "let x = null;
(x !== null) && x"
               LocMap.(empty |> add (mk_loc (2, 16) (2, 17)) (Not Null));
         "eq_undefined"
         >:: mk_ssa_builder_test
               "let x = undefined;
(x == undefined) && x"
               LocMap.(empty |> add (mk_loc (2, 20) (2, 21)) Maybe);
         "neq_undefined"
         >:: mk_ssa_builder_test
               "let x = undefined;
(x != undefined) && x"
               LocMap.(empty |> add (mk_loc (2, 20) (2, 21)) (Not Maybe));
         "strict_eq_undefined"
         >:: mk_ssa_builder_test
               "let x = undefined;
(x === undefined) && x"
               LocMap.(empty |> add (mk_loc (2, 21) (2, 22)) Undefined);
         "strit_neq_undefined"
         >:: mk_ssa_builder_test
               "let x = undefined;
(x !== undefined) && x"
               LocMap.(empty |> add (mk_loc (2, 21) (2, 22)) (Not Undefined));
         "undefined_already_bound"
         >:: mk_ssa_builder_test
               "let undefined = 3;
let x = null;
(x !== undefined) && x"
               LocMap.empty;
       ]
