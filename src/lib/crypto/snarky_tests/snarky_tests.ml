(* this is ugly, but [Core_kernel.String] doesn't have a [trim] function *)
let trim = String.trim

open Core_kernel

(* instantiate snarky for Vesta *)

module Impl = Snarky_backendless.Snark.Run.Make (struct
  include Kimchi_backend.Pasta.Vesta_based_plonk
  module Inner_curve = Kimchi_backend.Pasta.Pasta.Pallas
end)

(* helpers *)

let compare_with obtained filepath =
  let (_ : int) = Sys.command "tree" in
  let filepath = "examples/" ^ filepath in
  let expected = In_channel.read_all filepath in
  if String.(trim obtained <> trim expected) then (
    Format.printf "mismatch for %s detected\n" filepath ;
    Format.printf "expected:\n%s\n\n" expected ;
    Format.printf "obtained:\n%s\n" obtained ;
    failwith "circuit compilation has changed" )

let check_json ~input_typ ~return_typ ~circuit filename () =
  let cs : Impl.R1CS_constraint_system.t =
    Impl.constraint_system ~input_typ ~return_typ circuit
  in
  let serialized_json =
    Kimchi_backend.Pasta.Vesta_based_plonk.R1CS_constraint_system.to_json cs
  in
  compare_with serialized_json filename

(* monadic API tests *)

(** Both the monadic and imperative API will produce the same circuit hash. *)
let expected = "5357346d161dcccaa547c7999b8148db"

module MonadicAPI = struct
  module Impl = Snarky_backendless.Snark.Make (struct
    include Kimchi_backend.Pasta.Vesta_based_plonk
    module Inner_curve = Kimchi_backend.Pasta.Pasta.Pallas
  end)

  let main ((b1, b2) : Impl.Boolean.var * Impl.Boolean.var) =
    let open Impl in
    let%bind x = exists Boolean.typ ~compute:(As_prover.return true) in
    let%bind y = exists Boolean.typ ~compute:(As_prover.return true) in
    let%bind z = Boolean.(x &&& y) in
    let%bind b3 = Boolean.(b1 && b2) in

    let%bind () = Boolean.Assert.is_true z in
    let%bind () = Boolean.Assert.is_true b3 in

    Checked.return ()

  let get_hash_of_circuit () =
    let input_typ = Impl.Typ.tuple2 Impl.Boolean.typ Impl.Boolean.typ in
    let return_typ = Impl.Typ.unit in
    let cs : Impl.R1CS_constraint_system.t =
      Impl.constraint_system ~input_typ ~return_typ main
    in
    let digest = Md5.to_hex (Impl.R1CS_constraint_system.digest cs) in
    Format.printf "expected:\n%s\n\n" expected ;
    Format.printf "obtained:\n%s\n" digest ;
    assert (String.(digest = expected))
end

(* circuit-focused tests *)

module BooleanCircuit = struct
  module Request = struct
    type _ Snarky_backendless.Request.t +=
      | SimpleBool : bool Snarky_backendless.Request.t

    let handler (Snarky_backendless.Request.With { request; respond }) =
      match request with
      | SimpleBool ->
          respond (Provide true)
      | _ ->
          respond Unhandled
  end

  let input_typ = Impl.Typ.tuple2 Impl.Boolean.typ Impl.Boolean.typ

  let return_typ = Impl.Typ.unit

  let main ((b1, b2) : Impl.Boolean.var * Impl.Boolean.var) () =
    let x =
      Impl.exists Impl.Boolean.typ ~request:(fun _ -> Request.SimpleBool)
    in
    let y = Impl.exists Impl.Boolean.typ ~compute:(fun _ -> true) in

    let z = Impl.Boolean.(x && y) in
    let b3 = Impl.Boolean.(b1 && b2) in
    Impl.Boolean.Assert.is_true z ;
    Impl.Boolean.Assert.is_true b3 ;
    ()
end

module FieldCircuit = struct
  let input_typ = Impl.Field.typ

  let return_typ = Impl.Typ.unit

  let main (x : Impl.Field.t) () =
    let y = Impl.Field.one in
    let res = Impl.Field.(x + y) in
    let two = Impl.Field.of_int 2 in

    Impl.Field.Assert.equal res two ;
    Impl.Field.Assert.not_equal res Impl.Field.one ;
    Impl.Field.Assert.non_zero res
end

module RangeCircuits = struct
  let input_typ = Impl.Field.typ

  let return_typ = Impl.Typ.unit

  let lte (x : Impl.Field.t) () =
    Impl.Field.Assert.lte ~bit_length:2 x (Impl.Field.of_int 3) ;
    ()

  let gte (x : Impl.Field.t) () =
    Impl.Field.Assert.gte ~bit_length:2 x (Impl.Field.of_int 3) ;
    ()

  let gt (x : Impl.Field.t) () =
    Impl.Field.Assert.gt ~bit_length:2 x (Impl.Field.of_int 3) ;
    ()

  let lt (x : Impl.Field.t) () =
    Impl.Field.Assert.lt ~bit_length:2 x (Impl.Field.of_int 3) ;
    ()

  (** This function tests all the possible combinations for the range gates. *)
  let range_circuit ~(should_succeed : bool) (a : int) (b : int) =
    let bit_length = Impl.Field.size_in_bits - 2 in

    let circuit _ _ =
      let var_a =
        Impl.exists Impl.Field.typ ~compute:(fun _ ->
            Impl.Field.Constant.of_int a )
      in
      let var_b =
        Impl.exists Impl.Field.typ ~compute:(fun _ ->
            Impl.Field.Constant.of_int b )
      in

      match Int.compare a b with
      | 0 when should_succeed ->
          Impl.Field.Assert.gte ~bit_length var_a var_b ;
          Impl.Field.Assert.lte ~bit_length var_a var_b
      | 0 ->
          Impl.Field.Assert.gt ~bit_length var_a var_b ;
          Impl.Field.Assert.lt ~bit_length var_a var_b
      | x when (x > 0 && should_succeed) || (x < 0 && not should_succeed) ->
          Impl.Field.Assert.gte ~bit_length var_a var_b ;
          Impl.Field.Assert.gt ~bit_length var_a var_b
      | _ ->
          Impl.Field.Assert.lte ~bit_length var_a var_b ;
          Impl.Field.Assert.lt ~bit_length var_a var_b
    in
    (* try to generate witness *)
    let compiled =
      Impl.generate_witness ~input_typ:Impl.Typ.unit ~return_typ:Impl.Typ.unit
        circuit
    in
    match compiled () with
    | exception err when should_succeed ->
        Format.eprintf "[debug] exception when should_succeed: %s"
          (Exn.to_string err) ;
        false
    | exception _ when not should_succeed ->
        true
    | _ when not should_succeed ->
        false
    | _ ->
        true

  let test_range_gates =
    QCheck.Test.make ~count:10
      ~name:"test range gates during witness generation"
      (* TODO: it'd be nicer to generate actual fields directly, since that domain is most likely smaller *)
      QCheck.(tup3 bool pos_int pos_int)
      (fun (should_succeed, a, b) -> range_circuit ~should_succeed a b)

  let () =
    let res = range_circuit ~should_succeed:true 0 1 in
    assert res
end

module TernaryCircuit = struct
  let input_typ = Impl.Boolean.typ

  let return_typ = Impl.Typ.unit

  let main (x : Impl.Boolean.var) () =
    let two = Impl.Field.of_int 2 in
    let res = Impl.if_ x ~typ:Impl.Field.typ ~then_:two ~else_:Impl.Field.one in
    Impl.Field.Assert.equal res two
end

module PublicOutput = struct
  let input_typ = Impl.Boolean.typ

  let return_typ = Impl.Boolean.typ

  let main (x : Impl.Boolean.var) () : Impl.Boolean.var =
    Impl.Boolean.(x && Impl.Boolean.true_)
end

module InvalidWitness = struct
  open Impl

  (** A bit of a contrived circuit. 
      Here only a single constraint will be generated (due to constant unification),
      but we still want all [compute] closures to be checked when generating the witness. 
      Thus, this circuit should fail due to an invalid witness. *)
  let circuit _ =
    let one = constant Field.typ Field.Constant.one in
    for i = 0 to 2 do
      let b =
        exists Field.typ ~compute:(fun () -> Field.Constant.of_int (i + 1))
      in
      Field.Assert.equal b one
    done

  let negative_test_valid_witnesses () =
    let input_typ = Typ.unit in
    let return_typ = Typ.unit in
    let circuit _ _ = circuit () in
    match generate_witness ~input_typ ~return_typ circuit () with
    | exception _ ->
        ()
    | _ ->
        failwith "should have failed to generate a valid witness"
end

let circuit_tests =
  [ ( "boolean circuit"
    , `Quick
    , check_json ~input_typ:BooleanCircuit.input_typ
        ~return_typ:BooleanCircuit.return_typ ~circuit:BooleanCircuit.main
        "simple.json" )
  ; ( "circuit with field arithmetic"
    , `Quick
    , check_json ~input_typ:FieldCircuit.input_typ
        ~return_typ:FieldCircuit.return_typ ~circuit:FieldCircuit.main
        "field.json" )
  ; ( "circuit with ternary operator"
    , `Quick
    , check_json ~input_typ:TernaryCircuit.input_typ
        ~return_typ:TernaryCircuit.return_typ ~circuit:TernaryCircuit.main
        "ternary.json" )
  ; ( "circuit with public output"
    , `Quick
    , check_json ~input_typ:PublicOutput.input_typ
        ~return_typ:PublicOutput.return_typ ~circuit:PublicOutput.main
        "output.json" )
  ; ( "circuit with range check (less than equal)"
    , `Quick
    , check_json ~input_typ:RangeCircuits.input_typ
        ~return_typ:RangeCircuits.return_typ ~circuit:RangeCircuits.lte
        "range_lte.json" )
  ; ( "circuit with range check (greater than equal)"
    , `Quick
    , check_json ~input_typ:RangeCircuits.input_typ
        ~return_typ:RangeCircuits.return_typ ~circuit:RangeCircuits.gte
        "range_gte.json" )
  ; ( "circuit with range check (less than)"
    , `Quick
    , check_json ~input_typ:RangeCircuits.input_typ
        ~return_typ:RangeCircuits.return_typ ~circuit:RangeCircuits.lt
        "range_lt.json" )
  ; ( "circuit with range check (greater than)"
    , `Quick
    , check_json ~input_typ:RangeCircuits.input_typ
        ~return_typ:RangeCircuits.return_typ ~circuit:RangeCircuits.gt
        "range_gt.json" )
  ; ( "circuit with invalid witness"
    , `Quick
    , InvalidWitness.negative_test_valid_witnesses )
  ]

(* API tests *)

let get_hash_of_circuit () =
  let input_typ = Impl.Typ.tuple2 Impl.Boolean.typ Impl.Boolean.typ in
  let return_typ = Impl.Typ.unit in
  let cs : Impl.R1CS_constraint_system.t =
    Impl.constraint_system ~input_typ ~return_typ BooleanCircuit.main
  in
  let digest = Md5.to_hex (Impl.R1CS_constraint_system.digest cs) in
  Format.printf "expected:\n%s\n\n" expected ;
  Format.printf "obtained:\n%s\n" digest ;
  assert (String.(digest = expected))

let generate_witness () =
  let thing input _ = BooleanCircuit.main input () in
  let main_handled input () =
    Impl.handle (thing input) BooleanCircuit.Request.handler
  in

  let input_typ = Impl.Typ.tuple2 Impl.Boolean.typ Impl.Boolean.typ in
  let return_typ = Impl.Typ.unit in
  let f (inputs : Impl.Proof_inputs.t) _ = inputs in
  let compiled =
    Impl.generate_witness_conv ~f ~input_typ ~return_typ main_handled
  in

  let _b = compiled (true, true) in

  ()

module As_prover_circuits = struct
  let input_typ = Impl.Typ.tuple3 Impl.Field.typ Impl.Field.typ Impl.Field.typ

  let return_typ = Impl.Typ.unit

  let get_id =
    Snarky_backendless.Cvar.(
      function Var v -> v | _ -> failwith "should have been a var")

  let main as_prover vars
      ((b1, b2, b3) : Impl.Field.t * Impl.Field.t * Impl.Field.t) () =
    let abc = Impl.Field.(b1 + b2 + b3) in
    assert (get_id b1 = 1) ;
    if as_prover then
      Impl.as_prover (fun _ ->
          let f acc e =
            let var = Snarky_backendless.Cvar.Unsafe.of_index e in
            let v = Impl.As_prover.read_var var in
            Impl.Field.Constant.(acc + v)
          in
          let l = List.range 1 (vars + 1) in
          let total : Impl.field =
            List.fold l ~init:Impl.Field.Constant.one ~f
          in
          assert (not (Impl.Field.(Constant.compare total Constant.one) = 0)) ;
          assert (not Impl.Field.Constant.(equal total one)) ;
          () ) ;
    Impl.Field.Assert.non_zero abc ;

    ()

  let random_input = Impl.Field.Constant.(random (), random (), random ())

  module Tests = struct
    let generate_witness () =
      let f (inputs : Impl.Proof_inputs.t) _ = inputs in
      let compiled =
        Impl.generate_witness_conv ~f ~input_typ ~return_typ (main true 3)
      in

      let input = random_input in
      let _b = compiled input in

      ()

    (* test that all variables can be accessed*)
    let generate_witness_fails () =
      let f (inputs : Impl.Proof_inputs.t) _ = inputs in
      let compiled =
        Impl.generate_witness_conv ~f ~input_typ ~return_typ (main true 4)
      in

      let input = random_input in
      let _b = compiled input in

      ()

    (* test that accessing non existent vars fails*)
    let generate_witness_fails () =
      Alcotest.(
        check_raises "should fail accesing non existent var"
          (Failure "vector_get") generate_witness_fails)

    (* test that as_prover doesn't affect constraints *)
    let as_prover_does_nothing () =
      let get_hash as_prov =
        let cs : Impl.R1CS_constraint_system.t =
          Impl.constraint_system ~input_typ ~return_typ (main as_prov 3)
        in
        Md5.to_hex (Impl.R1CS_constraint_system.digest cs)
      in

      let digest1 = get_hash true in
      let digest2 = get_hash false in
      assert (String.(digest1 = digest2))
  end

  let as_prover_tests =
    [ ("access vars", `Quick, Tests.generate_witness)
    ; ("access non-existent vars", `Quick, Tests.generate_witness_fails)
    ; ("as_prover makes no constraints", `Quick, Tests.as_prover_does_nothing)
    ]
end

(****************************
 * outside-of-circuit tests *
 ****************************)

let out_of_circuit_constant () =
  let one = Impl.Field.Constant.one in
  let two = Impl.Field.Constant.of_int 2 in
  let x = Impl.Field.constant one in
  let y = Impl.Field.constant two in
  let _const_mul : Impl.Field.t = Impl.Field.mul x y in
  ()

let out_of_circuit_constraint () =
  let one = Impl.Field.constant Impl.Field.Constant.one in
  let two = Impl.Field.constant (Impl.Field.Constant.of_int 2) in
  Impl.Field.Assert.not_equal one two

let out_of_circuit_constraint () =
  Alcotest.(
    check_raises "should fail to create constraints outside of a circuit"
      (Failure "This function can't be run outside of a checked computation."))
    out_of_circuit_constraint

let outside_circuit_tests =
  [ ("out-of-circuit constant", `Quick, out_of_circuit_constant)
  ; ("out-of-circuit constraint (bad)", `Quick, out_of_circuit_constraint)
  ]

(* run tests *)

let api_tests =
  [ ("generate witness", `Quick, generate_witness)
  ; ("compile imperative API", `Quick, get_hash_of_circuit)
  ; ("compile monadic API", `Quick, MonadicAPI.get_hash_of_circuit)
  ]

(* run tests *)

let () =
  let range_checks =
    List.map ~f:QCheck_alcotest.to_alcotest [ RangeCircuits.test_range_gates ]
  in
  Alcotest.run "Simple snarky tests"
    [ ("outside of circuit tests", outside_circuit_tests)
    ; ("API tests", api_tests)
    ; ("circuit tests", circuit_tests)
    ; ("As_prover tests", As_prover_circuits.as_prover_tests)
    ; ("range checks", range_checks)
    ]
