Require Import Verdi.Verdi.

Require Import Cheerios.Cheerios.

Import DeserializerNotations.

Set Implicit Arguments.

Class LogParams `(P : MultiParams) :=
  {
    log_data_serializer :> Serializer data ;
    log_name_serializer :> Serializer name ;
    log_msg_serializer :> Serializer msg ;
    log_input_serializer :> Serializer input ;
    log_snapshot_interval : nat
  }.

Section Log.
  Context {orig_base_params : BaseParams}.
  Context {orig_multi_params : MultiParams orig_base_params}.
  Context {orig_failure_params : FailureParams orig_multi_params}.
  Context {log_params : LogParams orig_multi_params}.

  Definition entry : Type := input + (name * msg).

  Inductive log_files :=
  | Count
  | Snapshot
  | Log.

  Definition log_files_eq_dec : forall x y : log_files, {x = y} + {x <> y}.
    decide equality.
  Defined.

  Record log_state :=
    mk_log_state { log_num_entries : nat ;
                   log_data : data }.

  Definition log_state_serialize d :=
    serialize (log_num_entries d) +$+ serialize (log_data d).

  Definition log_state_deserialize :=
    n <- deserialize;;
    d <- deserialize;;
    ByteListReader.ret (mk_log_state n d).

  Lemma log_state_serialize_deserialize_id:
    serialize_deserialize_id_spec log_state_serialize log_state_deserialize.
  Proof.
    intros.
    unfold log_state_serialize, log_state_deserialize.
    destruct a.
    cheerios_crush.
  Qed.

  Instance log_state_Serializer : Serializer log_state.
  Proof.
    exact {| serialize := log_state_serialize ;
             deserialize := log_state_deserialize ;
             serialize_deserialize_id := log_state_serialize_deserialize_id
          |}.
  Qed.

  Definition log_net_handlers dst src m st : list (disk_op log_files) *
                                             list output *
                                             log_state *
                                             list (name * msg)  :=
    let '(out, data, ps) := net_handlers dst src m (log_data st) in
    let n := log_num_entries st in
    if S n =? log_snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inr (src , m) : entry)); Write Count (serialize (S n))],
          out,
          mk_log_state (S n) data,
          ps).

  Definition log_input_handlers h inp st : list (disk_op log_files) *
                                           list output *
                                           log_state *
                                           list (name * msg) :=
    let '(out, data, ps) := input_handlers h inp (log_data st) in
    let n := log_num_entries st in
    if S n =? log_snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inl inp : entry)); Write Count (serialize (S n))],
          out,
          mk_log_state (S n) data,
          ps).

  Instance log_base_params : BaseParams :=
    {
      data := log_state ;
      input := input ;
      output := output
    }.

  Definition log_init_handlers h :=
    mk_log_state 0 (init_handlers h).

  Definition init_disk (h : name) : do_disk log_files :=
    fun file =>
      match file with
      | Count => serialize 0
      | Snapshot => serialize (init_handlers h)
      | Log => IOStreamWriter.empty
      end.

  Instance log_multi_params : DiskOpMultiParams log_base_params :=
    {
      do_name := name;
      file_name := log_files;
      do_name_eq_dec := name_eq_dec;
      do_msg := msg;
      do_msg_eq_dec := msg_eq_dec;
      file_name_eq_dec := log_files_eq_dec;
      do_nodes := nodes;
      do_all_names_nodes := all_names_nodes;
      do_no_dup_nodes := no_dup_nodes;
      do_init_handlers := log_init_handlers;
      do_init_disk := init_disk;
      do_net_handlers := log_net_handlers;
      do_input_handlers := log_input_handlers
    }.

  Definition wire_to_log (w : file_name -> IOStreamWriter.wire) : option (nat * @data orig_base_params * list entry) :=
    match deserialize_top deserialize (w Count), deserialize_top deserialize (w Snapshot) with
    | Some n, Some d =>
      match deserialize_top (list_deserialize_rec _ _ n) (w Log) with
      | Some es => Some (n, d, es)
      | None => None
      end
    | _, _ => None
    end.

  Definition apply_entry h d e :=
    match e with
     | inl inp => let '(_, d', _) := input_handlers h inp d in d'
     | inr (src, m) => let '(_, d', _) := net_handlers h src m d in d'
    end.

  Fixpoint apply_log h (d : @data orig_base_params) (entries : list entry) : @data orig_base_params :=
    match entries with
    | [] => d
    | e :: entries => apply_log h (apply_entry h d e) entries
    end.

  Lemma apply_log_app : forall h d entries e,
      apply_log h d (entries ++ [e]) =
      apply_entry h (apply_log h d entries) e.
  Proof.
    intros.
    generalize dependent d.
    induction entries.
    - reflexivity.
    - intros.
      simpl.
      rewrite IHentries.
      reflexivity.
  Qed.

  Lemma serialize_empty : forall A,
    ByteListReader.unwrap (ByteListReader.ret (@nil A))
                          (IOStreamWriter.unwrap IOStreamWriter.empty) = Some ([], []).
  Proof.
    cheerios_crush.
  Qed.

  Lemma serialize_snoc : forall {A} {sA : Serializer A} (a : A) l,
      (IOStreamWriter.unwrap
         (list_serialize_rec _ _ l +$+ serialize a)) =
      (IOStreamWriter.unwrap (list_serialize_rec _ _ (l ++ [a]))).
  Proof.
    intros.
    induction l;
      rewrite IOStreamWriter.append_unwrap;
      simpl;
      repeat rewrite IOStreamWriter.append_unwrap.
    - rewrite IOStreamWriter.empty_unwrap.
      rewrite app_nil_r.
      reflexivity.
    - rewrite <- IHl.
      rewrite IOStreamWriter.append_unwrap, app_ass.
      reflexivity.
  Qed.

  Lemma serialize_deserialize_snoc : forall entries e0,
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S (length entries)))
        (IOStreamWriter.unwrap
           (list_serialize_rec entry _ (entries ++ [e0]))) =
      Some (entries ++ [e0], []).
  Proof.
    intros.
    induction entries.
    - simpl.
      cheerios_crush.
    - assert ((a :: entries) ++ [e0] = a :: entries ++ [e0]) by reflexivity.
      rewrite H.
      unfold list_deserialize_rec.
      rewrite sequence_rewrite.
      rewrite ByteListReader.bind_unwrap.
      rewrite ByteListReader.map_unwrap.
      simpl.
      rewrite IOStreamWriter.append_unwrap.
      rewrite serialize_deserialize_id.
      rewrite ByteListReader.bind_unwrap.
      unfold list_deserialize_rec in IHentries.
      rewrite IHentries.
      cheerios_crush.
  Qed.

  Theorem serialize_snoc' : forall e entries dsk n,
      dsk Log = list_serialize_rec entry _ entries ->
      n = length entries ->
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S n))
        (IOStreamWriter.unwrap
           (apply_ops dsk [Append Log (serialize e); Write Count (serialize (S n))] Log)) = Some (entries ++ [e], []).
  Proof.
    unfold apply_ops, update_disk, update.
    repeat break_if;
      try congruence.
    intros.
    rewrite H.
    rewrite serialize_snoc.
    rewrite H0.
    rewrite serialize_deserialize_snoc.
    reflexivity.
  Qed.

  Lemma log_net_handlers_spec :
    forall dst src m d cs out d' l
           (dsk : do_disk file_name) (n : nat) snap (entries : list entry)
           dsk' n' snap' entries',
      log_net_handlers dst src m (mk_log_state n d) = (cs, out, mk_log_state n' d', l) ->
      ByteListReader.unwrap (@deserialize nat _)
                            (IOStreamWriter.unwrap (dsk Count)) = Some (n, []) ->
      ByteListReader.unwrap deserialize (IOStreamWriter.unwrap (dsk Snapshot)) = Some (snap, []) ->
      dsk Log = list_serialize_rec entry _ entries ->
      n = length entries ->
      apply_log dst snap entries = d ->
      apply_ops dsk cs = dsk' ->
      ByteListReader.unwrap deserialize
                            (IOStreamWriter.unwrap (dsk' Count)) = Some (n', [])  ->
      ByteListReader.unwrap deserialize
                            (IOStreamWriter.unwrap (dsk' Snapshot)) = Some (snap', []) ->
      ByteListReader.unwrap (list_deserialize_rec _  _ n')
                            (IOStreamWriter.unwrap (dsk' Log)) = Some (entries', []) ->
      apply_log dst snap' entries' = d'.
  Proof.
    intros.
    unfold log_net_handlers in *.
    break_if.
    - break_let. break_let.
      assert (dsk' Count = serialize 0).
      * find_inversion.
        reflexivity.
      * match goal with
        | H : dsk' Count = _ |- _ => rewrite H in *
        end.
        match goal with
        | H : context [serialize 0] |- _ => rewrite serialize_deserialize_id_nil in H
        end.
        find_inversion. find_inversion.
        simpl in *. repeat break_if; try congruence.
        match goal with
        | H : context [IOStreamWriter.empty] |- _ => rewrite serialize_empty in H
        end.
        find_inversion. find_inversion.
        match goal with
        | H : _ = Some (snap', _) |- _ => rewrite serialize_deserialize_id_nil in H
        end.
        simpl.
        find_inversion.
        reflexivity.
    - break_let. break_let.
      assert (Hn' : n' = S n).
      + find_inversion. simpl in *.
        reflexivity.
      + rewrite Hn' in *.
        assert (Hentries' : entries' = entries ++ [inr (src, m)]).
        {
          match goal with
          | H : _ = dsk' |- _ => rewrite <- H in *
          end.
          tuple_inversion.
          match goal with
          | H : _ = Some (entries', _) |- _ =>  rewrite (serialize_snoc' _ entries) in H
          end.
          * find_inversion. reflexivity.
          * assumption.
          * reflexivity.
        }
        assert (Hsnap' : snap' = snap).
        * find_inversion.
          match goal with
          | H : _ = Some (snap', _) |- _ => simpl in H; repeat break_if; try congruence
          end.
        * rewrite Hsnap', Hentries'.
          rewrite apply_log_app.
          match goal with
          | H : _ = d |- _ => rewrite H
          end.
          unfold apply_entry. repeat break_let.
          inversion H.
          match goal with
          | H : _ = ?d |- _ = ?d => rewrite <- H
          end.
          match goal with
          | H : net_handlers _ _ _ _ = _ |- _ => simpl in H; rewrite H in *
          end.
          find_inversion.
          reflexivity.
  Qed.

  Lemma log_input_handlers_spec
    : forall dst m d cs out d' l
             (dsk : do_disk file_name) (n : nat) snap (entries : list entry)
             dsk' n' snap' entries',
      log_input_handlers dst m (mk_log_state n d) = (cs, out, mk_log_state n' d', l) ->
      ByteListReader.unwrap (@deserialize nat _)
                            (IOStreamWriter.unwrap (dsk Count)) = Some (n, []) ->
      ByteListReader.unwrap deserialize (IOStreamWriter.unwrap (dsk Snapshot)) = Some (snap, []) ->
      dsk Log = list_serialize_rec entry _ entries ->
      n = length entries ->
      apply_log dst snap entries = d ->
      apply_ops dsk cs = dsk' ->
      ByteListReader.unwrap deserialize
                            (IOStreamWriter.unwrap (dsk' Count)) = Some (n', [])  ->
      ByteListReader.unwrap deserialize
                            (IOStreamWriter.unwrap (dsk' Snapshot)) = Some (snap', []) ->
      ByteListReader.unwrap (list_deserialize_rec _  _ n')
                            (IOStreamWriter.unwrap (dsk' Log)) = Some (entries', []) ->
      apply_log dst snap' entries' = d'.
  Proof.
    intros.
    unfold log_input_handlers in *.
    break_if.
    - break_let. break_let.
      assert (dsk' Count = serialize 0).
      * find_inversion.
        simpl.
        reflexivity.
      * match goal with
        | H : dsk' Count = _ |- _ => rewrite H in *
        end.
        match goal with
        | H : context [serialize 0] |- _ => rewrite serialize_deserialize_id_nil in H
        end.
        find_inversion. find_inversion.
        simpl in *. repeat break_if; try congruence.
        match goal with
        | H : context [IOStreamWriter.empty] |- _ => rewrite serialize_empty in H
        end.
        find_inversion. find_inversion.
        match goal with
        | H : _ = Some (snap', _) |- _ => rewrite serialize_deserialize_id_nil in H
        end.
        simpl.
        find_inversion.
        reflexivity.
    - break_let. break_let.
      assert (Hn' : n' = S n).
      + find_inversion. simpl in *.
        reflexivity.
      + rewrite Hn' in *.
        assert (Hentries' : entries' = entries ++ [inl m]).
        {
          match goal with
          | H : _ = dsk' |- _ => rewrite <- H in *
          end.
          tuple_inversion.
          match goal with
          | H : _ = Some (entries', _) |- _ =>  rewrite (serialize_snoc' _ entries) in H
          end.
          * find_inversion. reflexivity.
          * assumption.
          * reflexivity.
        }
        assert (Hsnap' : snap' = snap).
        * find_inversion.
          match goal with
          | H : _ = Some (snap', _) |- _ => simpl in H; repeat break_if; try congruence
          end.
        * rewrite Hsnap', Hentries'.
          rewrite apply_log_app.
          match goal with
          | H : _ = d |- _ => rewrite H
          end.
          unfold apply_entry. repeat break_let.
          inversion H.
          match goal with
          | H : _ = ?d |- _ = ?d => rewrite <- H
          end.
          match goal with
          | H : input_handlers _ _ _ = _ |- _ => simpl in H; rewrite H in *
          end.
          find_inversion.
          reflexivity.
  Qed.

  Definition do_log_reboot (h : do_name) (w : log_files -> IOStreamWriter.wire) :
    data * do_disk log_files :=
    match wire_to_log w with
    | Some (n, d, es) => (mk_log_state 0 (reboot (apply_log h d es)),
                              fun file => match file with
                                         | Count => serialize 0
                                         | Snapshot => serialize d
                                         | Log => IOStreamWriter.empty
                                         end)
    | None => (mk_log_state 0 (reboot (init_handlers h)), fun _ => IOStreamWriter.empty)
    end.

  Instance log_failure_params : DiskOpFailureParams log_multi_params :=
    { do_reboot := do_log_reboot }.
End Log.

Hint Extern 5 (@BaseParams) => apply log_base_params : typeclass_instances.
Hint Extern 5 (@DiskOpMultiParams _) => apply log_multi_params : typeclass_instances.
Hint Extern 5 (@DiskOpFailureParams _ _) => apply log_failure_params : typeclass_instances.
