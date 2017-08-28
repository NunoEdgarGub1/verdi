Require Import Verdi.Verdi.
Require Import Verdi.HandlerMonad.

Require Import Cheerios.Cheerios.

Local Arguments update {_} {_} _ _ _ _ _ : simpl never.

Set Implicit Arguments.

Inductive Name := primary | backup.
Definition Name_eq_dec : forall x y : Name, {x = y} + {x <> y}.
  decide equality.
Defined.

Inductive Msg := inc | ack.
Definition Msg_eq_dec : forall x y : Msg, {x = y} + {x <> y}.
  decide equality.
Defined.

Inductive Input := request_inc.
Definition Input_eq_dec : forall x y : Input, {x = y} + {x <> y}.
  destruct x,y. auto.
Defined.

Inductive Output := inc_executed.
Definition Output_eq_dec : forall x y : Output, {x = y} + {x <> y}.
  destruct x,y. auto.
Defined.

Record Data := mkData { count : nat }.

Definition init_Data : Data := mkData 0.

Definition Handler (S : Type) := GenHandler (Name * Msg) S Output unit.

Definition PrimaryNetHandler (m : Msg) : Handler Data :=
  match m with
  | ack => write_output inc_executed
  | _ => nop
  end.

Definition PrimaryInputHandler (i : Input) : Handler Data :=
  match i with
  | request_inc =>
    st <- get ;;
    put (mkData (S (count st))) ;;
    send (backup, inc)
  end.

Definition BackupNetHandler (m : Msg) : Handler Data :=
  match m with
  | inc =>
    st <- get ;;
    put (mkData (S (count st))) ;;
    send (primary, ack)
  | _ => nop
  end.

Definition BackupInputHandler (i : Input) : Handler Data := nop.

Definition NetHandler (me : Name) (m : Msg) : Handler Data :=
  match me with
  | primary => PrimaryNetHandler m
  | backup => BackupNetHandler m
  end.

Definition InputHandler (me : Name) (i : Input) : Handler Data :=
  match me with
  | primary => PrimaryInputHandler i
  | backup => BackupInputHandler i
  end.

Instance Counter_BaseParams : BaseParams :=
  {
    data := Data;
    input := Input;
    output := Output
  }.

Definition Nodes : list Name := [primary; backup].

Lemma all_Names_Nodes : forall n, In n Nodes.
Proof.
  destruct n; simpl; auto.
Qed.

Lemma NoDup_Nodes : NoDup Nodes.
Proof.
  repeat constructor; simpl; intuition discriminate.
Qed.

Import DeserializerNotations.

Definition Data_serialize (d : Data) : IOStreamWriter.t :=
  serialize x00 +$+ serialize (count d).

Definition Data_deserialize : ByteListReader.t Data :=
  tag <- deserialize ;;
  match tag with
  | x00 => mkData <$> deserialize
  | _ => ByteListReader.error
  end.

Lemma Data_serialize_deserialize_id :
  serialize_deserialize_id_spec Data_serialize Data_deserialize.
Proof.
  intros.
  unfold Data_serialize, Data_deserialize.
  destruct a.
  repeat (cheerios_crush; simpl).
Qed.

Instance Data_Serializer : Serializer Data :=
  {
    serialize := Data_serialize;
    deserialize := Data_deserialize;
    serialize_deserialize_id := Data_serialize_deserialize_id
  }.

Definition disk_reboot (s : IOStreamWriter.wire) : Data := 
  match deserialize_top deserialize s with
  | Some d => d
  | None => init_Data
  end.

Definition DiskNetHandler dst (src : Name) m st :=
  let '(out, data, ps) := runGenHandler_ignore st (NetHandler dst m) in
  (serialize_top (serialize data), out, data, ps).

Definition DiskInputHandler h inp st :=
  let '(out, data, ps) := runGenHandler_ignore st (InputHandler h inp) in
  (serialize_top (serialize data), out, data, ps).

Instance Counter_DiskMultiParams : DiskMultiParams Counter_BaseParams :=
  {
    d_name := Name;
    d_name_eq_dec := Name_eq_dec;
    d_msg := Msg;
    d_msg_eq_dec := Msg_eq_dec;
    d_nodes := Nodes;
    d_all_names_nodes := all_Names_Nodes;
    d_no_dup_nodes := NoDup_Nodes;
    disk := IOStreamWriter.wire;
    d_init_handlers := fun _ => init_Data;
    d_init_disk := fun _ => serialize_top IOStreamWriter.empty;
    d_net_handlers := DiskNetHandler;
    d_input_handlers := DiskInputHandler
  }.

Instance Counter_FailureParams : DiskFailureParams Counter_DiskMultiParams :=
  {
    d_reboot := fun _ => disk_reboot
  }.

(*
Lemma net_handlers_NetHandler :
  forall h src m d os d' ms dsk,
    d_net_handlers h src m d = (dsk, os, d', ms) ->
    DiskNetHandler h src m d = (dsk, os, d', ms).
Proof.
  intros.
  simpl in *.
  unfold DiskNetHandler in *.
  monad_unfold.
  repeat break_let.
  auto.
Qed.

Lemma input_handlers_InputHandlers :
  forall h i d os d' ms dsk,
    d_input_handlers h i d = (dsk, os, d', ms) ->
    InputHandler h i d = (dsk, os, d', ms).
Proof.
  intros.
  simpl in *.
  monad_unfold.
  repeat break_let.
  auto.
Qed.
*)

Lemma PrimaryNetHandler_no_msgs :
  forall m d ms d' o u,
    PrimaryNetHandler m  d = (u, o, d', ms) ->
    ms = [].
Proof.
  unfold PrimaryNetHandler.
  intros. monad_unfold.
  repeat break_match; repeat find_inversion; auto.
Qed.

Definition inc_in_flight_to_backup (l : list d_packet) : nat :=
  length (filterMap
            (fun p => if d_msg_eq_dec (d_pBody p) inc
                   then if d_name_eq_dec (d_pDst p) backup
                        then Some tt else None
                   else None)
            l).

Lemma inc_in_flight_to_backup_app :
  forall xs ys,
    inc_in_flight_to_backup (xs ++ ys) = inc_in_flight_to_backup xs + inc_in_flight_to_backup ys.
Proof.
  intros.
  unfold inc_in_flight_to_backup.
  rewrite filterMap_app.
  rewrite app_length.
  auto.
Qed.

Lemma inc_in_flight_to_backup_cons_primary_dst :
  forall p,
    d_pDst p = primary ->
    inc_in_flight_to_backup [p] = 0.
Proof.
  intros.
  unfold inc_in_flight_to_backup.
  simpl.
  repeat break_match; try congruence; auto.
Qed.

Lemma inc_in_flight_to_backup_nil :
  inc_in_flight_to_backup [] = 0.
Proof.
  reflexivity.
Qed.

Lemma InputHandler_inc_in_flight_to_backup_preserved :
  forall h i d u o d' l,
    InputHandler h i d = (u, o, d', l) ->
    count d' = count d + inc_in_flight_to_backup (d_send_packets h l).
Proof.
  unfold InputHandler, PrimaryInputHandler, BackupInputHandler.
  simpl.
  intros.
  monad_unfold.
  repeat break_match; repeat find_inversion; compute; auto.
  rewrite plus_comm. auto.
Qed.

Lemma NetHandler_inc_in_flight_to_backup_preserved :
  forall p d u o d' l,
    NetHandler (d_pDst p) (d_pBody p) d = (u, o, d', l) ->
    count d' + inc_in_flight_to_backup (d_send_packets (d_pDst p) l) = count d + inc_in_flight_to_backup [p].
Proof.
  unfold NetHandler, PrimaryNetHandler, BackupNetHandler.
  intros.
  monad_unfold.
  destruct p. simpl in *.
  repeat break_match; repeat find_inversion; simpl; try rewrite inc_in_flight_to_backup_nil; compute;
  auto with *.
Qed.

Lemma InputHandler_backup_no_msgs :
  forall i d u o d' l,
    InputHandler backup i d = (u, o, d', l) ->
    l = [].
Proof.
  simpl. unfold InputHandler, BackupInputHandler.
  intros.
  monad_unfold.
  find_inversion.
  auto.
Qed.

Lemma cons_is_app :
  forall A (x : A) xs,
    x :: xs = [x] ++ xs.
Proof.
  auto.
Qed.


Lemma backup_plus_network_eq_primary :
  forall net tr,
    step_async_disk_star (params := Counter_DiskMultiParams)
                         step_async_disk_init
                         net tr -> 
    count (nwdState net backup) + inc_in_flight_to_backup (nwdPackets net) = count (nwdState net primary).
Proof.
  intros.
  remember step_async_disk_init as y in *.
  revert Heqy.
  induction H using refl_trans_1n_trace_n1_ind; intros; subst.
  - reflexivity.
  - concludes.
    match goal with
    | [ H : step_async_disk _ _ _ |- _ ] => invc H
    end; simpl.
    + unfold d_net_handlers in *.
      simpl in *.
      unfold DiskNetHandler in *.
      repeat break_let.
      unfold runGenHandler_ignore in *.
      repeat break_let.
      repeat find_inversion.
      find_copy_apply_lem_hyp NetHandler_inc_in_flight_to_backup_preserved.
      repeat find_rewrite.
      rewrite cons_is_app in IHrefl_trans_1n_trace1.
      repeat rewrite inc_in_flight_to_backup_app in *.
      destruct (d_pDst p) eqn:?;
               try rewrite update_same;
        try rewrite update_diff by congruence;
        unfold d_send_packets in *; simpl in *.
      * erewrite PrimaryNetHandler_no_msgs with (ms := l) in * by eauto.
        simpl in *. rewrite inc_in_flight_to_backup_nil in *.
        rewrite inc_in_flight_to_backup_cons_primary_dst in *;
          (repeat rewrite <- plus_n_O in *);
           simpl in *;
           try rewrite H0;
           assumption.
      * omega.
    + unfold d_input_handlers in *.
      simpl in *.
      unfold DiskInputHandler in *.
      repeat break_let.
      unfold runGenHandler_ignore in *.
      repeat break_let.
      repeat find_inversion.
      find_copy_apply_lem_hyp InputHandler_inc_in_flight_to_backup_preserved.
      unfold d_send_packets in *. simpl in *.
      rewrite inc_in_flight_to_backup_app. subst.
      destruct h eqn:?;
               try rewrite update_same;
        try rewrite update_diff by congruence.
      * omega.
      * revert H0.
        erewrite InputHandler_backup_no_msgs with (l := l) by eauto.
        simpl.
        rewrite inc_in_flight_to_backup_nil.
        intros.
        omega.
Qed.

Theorem primary_ge_backup :
  forall net tr,
    step_async_disk_star (params := Counter_DiskMultiParams) step_async_disk_init net tr ->
    count (nwdState net backup) <= count (nwdState net primary).
Proof.
  intros.
  apply backup_plus_network_eq_primary in H.
  auto with *.
Qed.

Definition trace_inputs (tr : list (d_name * (input + list output))) : nat :=
  length (filterMap (fun e => match e with
                           | (primary, inl i) => Some i
                           | _ => None
                           end) tr).
Lemma trace_inputs_app :
  forall tr1 tr2,
    trace_inputs (tr1 ++ tr2) = trace_inputs tr1 + trace_inputs tr2.
Proof.
  unfold trace_inputs.
  intros.
  rewrite filterMap_app.
  rewrite app_length. auto.
Qed.

Definition trace_outputs (tr : list (d_name * (input + list output))) : nat :=
  length (filterMap (fun e => match e with
                           | (primary, inr [o]) => Some o
                           | _ => None
                           end) tr).

Lemma trace_outputs_app :
  forall tr1 tr2,
    trace_outputs (tr1 ++ tr2) = trace_outputs tr1 + trace_outputs tr2.
Proof.
  unfold trace_outputs.
  intros.
  rewrite filterMap_app.
  rewrite app_length. auto.
Qed.

Definition ack_in_flight_to_primary (l : list d_packet) : nat :=
  length (filterMap
            (fun p => if d_msg_eq_dec (d_pBody p) ack
                   then if d_name_eq_dec (d_pDst p) primary
                        then Some tt else None
                   else None)
            l).

Lemma ack_in_flight_to_primary_app :
  forall xs ys,
    ack_in_flight_to_primary (xs ++ ys) = ack_in_flight_to_primary xs + ack_in_flight_to_primary ys.
Proof.
  unfold ack_in_flight_to_primary.
  intros.
  rewrite filterMap_app.
  rewrite app_length. auto.
Qed.

Lemma ack_in_flight_to_primary_backup :
  forall p,
    d_pDst p = backup ->
    ack_in_flight_to_primary [p] = 0.
Proof.
  intros.
  unfold ack_in_flight_to_primary.
  simpl.
  repeat break_match; try congruence; auto.
Qed.


Lemma InputHandler_trace_preserved :
  forall h i d u o d' l,
    InputHandler h i d = (u, o, d', l) ->
    trace_inputs [(h, inl i)] =
    trace_outputs [(h, inr o)] +
    inc_in_flight_to_backup (d_send_packets h l) +
    ack_in_flight_to_primary (d_send_packets h l).
Proof.
  unfold InputHandler, PrimaryInputHandler, BackupInputHandler.
  simpl.
  intros.
  monad_unfold.
  repeat break_match; repeat find_inversion; compute; auto.
Qed.

Lemma NetHandler_trace_preserved :
  forall p d u o d' l,
    NetHandler (d_pDst p) (d_pBody p) d = (u, o, d', l) ->
    inc_in_flight_to_backup [p] +
    ack_in_flight_to_primary [p] =
    trace_outputs [((d_pDst p), inr o)] +
    inc_in_flight_to_backup (d_send_packets (d_pDst p) l) +
    ack_in_flight_to_primary (d_send_packets (d_pDst p) l).
Proof.
  unfold NetHandler, PrimaryNetHandler, BackupNetHandler.
  intros.
  monad_unfold.
  destruct p. simpl in *.
  repeat break_match; repeat find_inversion; simpl; try rewrite inc_in_flight_to_backup_nil;
  compute;
  auto with *.
Qed.

Lemma trace_inputs_output :
  forall h os,
    trace_inputs [(h, inr os)] = 0.
Proof.
  intros.
  unfold trace_inputs.
  simpl. repeat break_match; simpl; congruence.
Qed.

Lemma trace_outputs_input :
  forall h i,
    trace_outputs [(h, inl i)] = 0.
Proof.
  intros.
  unfold trace_outputs.
  simpl. repeat break_match; simpl; congruence.
Qed.

Lemma trace_outputs_backup :
  forall e,
    trace_outputs [(backup, e)] = 0.
Proof.
  auto.
Qed.

Lemma inputs_eq_outputs_plus_inc_plus_ack :
  forall net tr,
    step_async_disk_star (params := Counter_DiskMultiParams) step_async_disk_init net tr ->
    trace_inputs tr = trace_outputs tr +
                      inc_in_flight_to_backup (nwdPackets net) +
                      ack_in_flight_to_primary (nwdPackets net).
Proof.
  intros.
  remember step_async_disk_init as y in *.
  revert Heqy.
  induction H using refl_trans_1n_trace_n1_ind; intros; subst.
  - reflexivity.
  - concludes.
    match goal with
    | [ H : step_async_disk _ _ _ |- _ ] => invc H
    end; simpl.
    + unfold d_net_handlers in *.
      simpl in *.
      unfold DiskNetHandler in *.
      repeat break_let.
      unfold runGenHandler_ignore in *.
      repeat break_let.
      repeat find_inversion.
      repeat find_rewrite.
      rewrite trace_inputs_app.
      rewrite trace_outputs_app.
      rewrite cons_is_app with (x := p) in *.
      repeat rewrite inc_in_flight_to_backup_app in *.
      repeat rewrite ack_in_flight_to_primary_app in *.
      find_apply_lem_hyp NetHandler_trace_preserved.
      destruct (d_pDst p) eqn:?.
      * erewrite inc_in_flight_to_backup_cons_primary_dst in * by eauto.
        rewrite trace_inputs_output in *. simpl in  *. omega.
      * rewrite ack_in_flight_to_primary_backup in * by auto.
        rewrite trace_outputs_backup in *. unfold send_packets in *.
        simpl in *. rewrite <- plus_n_O in *. omega.
    + unfold d_input_handlers in *.
      simpl in *.
      unfold DiskInputHandler in *.
      repeat break_let.
      unfold runGenHandler_ignore in *.
      repeat break_let.
      repeat find_inversion.
      find_apply_lem_hyp InputHandler_trace_preserved.
      rewrite cons_is_app.
      repeat rewrite trace_inputs_app.
      repeat rewrite trace_outputs_app.
      repeat rewrite inc_in_flight_to_backup_app in *.
      repeat rewrite ack_in_flight_to_primary_app in *.
      rewrite trace_outputs_input.
      rewrite trace_inputs_output.
      unfold send_packets in *. simpl in *. omega.
Qed.

Theorem inputs_ge_outputs :
  forall net tr,
    step_async_disk_star (params := Counter_DiskMultiParams) step_async_disk_init net tr ->
    trace_outputs tr <= trace_inputs tr.
Proof.
  intros.
  apply inputs_eq_outputs_plus_inc_plus_ack in H.
  omega.
Qed.

Theorem net_handlers_reboot : forall node net p out d l dsk,
    d_net_handlers node (d_pSrc p) (d_pBody p) (nwdState net node) = (dsk, out, d, l) ->
    disk_reboot (update Name_eq_dec (nwdDisk net) node dsk node) =
    update Name_eq_dec (nwdState net) node d node.
Proof.
  intros.
  simpl in *.
  destruct node; unfold DiskNetHandler, runGenHandler_ignore, NetHandler, PrimaryNetHandler, BackupNetHandler, disk_reboot in *.
  - repeat break_let.
    repeat break_match.
    * repeat find_inversion.
      update_destruct_max_simplify; try congruence.
      pose proof (serialize_deserialize_top_id d).
      unfold deserialize, serialize in H.
      simpl in H.
      find_rewrite.
      find_injection.
      reflexivity.
    * repeat find_inversion.
      update_destruct_max_simplify; try congruence.
      pose proof (serialize_deserialize_top_id d).
      unfold deserialize, serialize in H.
      simpl in H.
      find_rewrite.
      find_injection.
      reflexivity.
    * repeat find_inversion.
      update_destruct_max_simplify; try congruence.
      pose proof (serialize_deserialize_top_id d).
      unfold deserialize, serialize in H.
      simpl in H.
      congruence.
    * repeat find_inversion.
      update_destruct_max_simplify; try congruence.
      pose proof (serialize_deserialize_top_id d).
      unfold deserialize, serialize in H.
      simpl in H.
      find_rewrite.
      congruence.
   - repeat break_let.
     repeat break_match.
     * repeat find_inversion.
       monad_unfold.
       simpl in *.
       find_injection.
       update_destruct_max_simplify; try congruence.
       pose proof (serialize_deserialize_top_id {| count := S (count (nwdState net backup)) |}).
       unfold deserialize, serialize in H.
       simpl in H.
       find_rewrite.
       find_injection.
       reflexivity.
     * repeat find_inversion.
       update_destruct_max_simplify; try congruence.
       pose proof (serialize_deserialize_top_id d).
       unfold deserialize, serialize in H.
       simpl in H.
       find_rewrite.
       find_inversion.
       reflexivity.
     * repeat find_inversion.
       update_destruct_max_simplify; try congruence.
       pose proof (serialize_deserialize_top_id d).
       unfold deserialize, serialize in H.
       simpl in H.
       find_rewrite.
       congruence.
     * repeat find_inversion.
       update_destruct_max_simplify; try congruence.
       pose proof (serialize_deserialize_top_id d).
       unfold deserialize, serialize in H.
       simpl in H.
       find_rewrite.
       congruence.
Qed.

Theorem input_handlers_reboot : forall node net inp out d l dsk,
    d_input_handlers node inp (nwdState net node) = (dsk, out, d, l) ->
      disk_reboot (update Name_eq_dec (nwdDisk net) node dsk node) =
      update Name_eq_dec (nwdState net) node d node.
Proof.
  intros.
  simpl in *.
  destruct node; unfold DiskInputHandler, runGenHandler_ignore, InputHandler, PrimaryInputHandler, BackupInputHandler, disk_reboot in *.
  monad_unfold;
    repeat break_let;
    repeat break_match;
    repeat find_inversion.
  - update_destruct_max_simplify; try congruence.
    pose proof (serialize_deserialize_top_id {| count := S (count (nwdState net primary)) |}).
    unfold deserialize, serialize in H.
    simpl in H.
    find_rewrite.
    find_injection.
    reflexivity.
  - update_destruct_max_simplify; try congruence.
    pose proof (serialize_deserialize_top_id {| count := S (count (nwdState net primary)) |}).
    simpl in H.
    find_rewrite.
    congruence.
  - repeat break_let.
    repeat find_inversion.
    update_destruct_max_simplify; try congruence.
    pose proof (serialize_deserialize_top_id d).
    unfold deserialize, serialize in H.
    simpl in H.
    rewrite H.
    reflexivity.
Qed.

Theorem disk_follows_local_state: forall net tr h,
    step_async_disk_star step_async_disk_init net tr ->
    disk_reboot (nwdDisk net h) = nwdState net h.
Proof.
  intros.
  remember step_async_disk_init as y in *.
  revert Heqy.
  induction H using refl_trans_1n_trace_n1_ind; intros; subst.
  - simpl.    
    unfold init_Data, disk_reboot.
    unfold deserialize_top, serialize_top; simpl.
    rewrite IOStreamWriter.wire_wrap_unwrap.
    rewrite IOStreamWriter.empty_unwrap.
    unfold Data_deserialize.
    cheerios_crush.
  - concludes.
    match goal with
    | [ H : step_async_disk _ _ _ |- _ ] => invc H
    end; simpl.
    + match goal with
      | [H : d_net_handlers _ _ _ _ = _ |- _] =>
        apply net_handlers_reboot in H
      end.
      update_destruct_max_simplify; auto.
    + match goal with
      | [H : d_input_handlers ?node _ _ = _ |- _] =>
        apply input_handlers_reboot in H
      end.
      update_destruct_max_simplify; auto.
Qed.
