-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- Segreteria e compensi staff — consegna 29 ott 2026 (portale v3.148)
-- Principio (Marco, 29 ott): la segreteria è la verità.
--
-- DA LANCIARE A MANO da Marco nel SQL Editor di Supabase, TUTTO IN UNA VOLTA, dopo averlo letto.
-- Prima questo file, poi il push del portale (il portale v3.148 passa p_slot_ids ad allineamento_decidi:
-- con la funzione vecchia la scelta "registra" darebbe errore).
--
-- Il risultato finale è una tabellina PRIMA / DOPO con i controlli. Per leggere le viste che filtrano
-- per utente (auth.uid() / is_segreteria()) i controlli girano "come Marco" (staff_creator) solo dentro
-- questa transazione: set_config(..., true) vale fino al COMMIT.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{"sub":"27b04151-93a7-4ecc-824c-fe337cc631a6","role":"authenticated"}', true);

DROP TABLE IF EXISTS _controllo_291026;
CREATE TEMP TABLE _controllo_291026 (n serial, momento text, controllo text, valore text);

-- ───────────────────────────── CONTROLLI PRIMA ─────────────────────────────
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '1. firma allineamento_decidi', string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
 WHERE s.nspname = 'public' AND p.proname = 'allineamento_decidi';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '2. cambia_giorni_abbonamento blocca il cambio di numero di giorni', (prosrc LIKE '%cambia il prezzo%')::text
  FROM pg_proc WHERE oid = 'public.cambia_giorni_abbonamento(uuid,uuid[],text)'::regprocedure;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '3a. lezioni di Mellozzini su Expert/Giovani NON a percentuale (dopo: 0)', count(*)::text
  FROM public.impegni_staff WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND tipo = 'lezione' AND compenso_tipo <> 'percentuale';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '3b. lezioni di Mellozzini su Expert/Giovani pagate a lezione, euro > 0 (dopo: 0)', count(*)::text
  FROM public.v_compenso_lezioni WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND euro > 0;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '3c. lezioni di Mellozzini su Expert/Giovani da confermare (restano uguali: servono per le sostituzioni)', count(*)::text
  FROM public.v_compenso_lezioni WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND da_confermare;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '4. Prime Lezioni nella stessa ora di un corso dello stesso istruttore pagate, euro > 0 (dopo: 0)', count(*)::text
  FROM public.v_compenso_lezioni v
 WHERE v.tipo_corso LIKE 'prima_lezione%' AND v.euro > 0
   AND EXISTS (SELECT 1 FROM public.impegni_staff o JOIN public.corsi_attivi_settimanali oc ON oc.id = o.slot_id
                WHERE o.user_id = v.user_id AND o.data = v.data AND o.id <> v.impegno_id AND o.tipo = 'lezione'
                  AND o.stato IN ('previsto','presente') AND oc.tipo_corso NOT LIKE 'prima_lezione%'
                  AND o.ora_inizio < v.ora_fine AND o.ora_fine > v.ora_inizio);

-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- 1. "Da sistemare" → registra abbonamento: i giorni del corso
--    (caso Arianna Calcaterra, Corso Genitori: "Scegli almeno un giorno del corso" senza caselle)
--    allineamento_decidi prende p_slot_ids e lo passa a registra_abbonamento.
--    Un parametro in più = una funzione nuova (overload): si toglie la firma vecchia e si ricrea.
--    SECURITY DEFINER, search_path e permessi come prima (postgres, authenticated, service_role).
-- ═══════════════════════════════════════════════════════════════════════════════════════════
DROP FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date);

CREATE FUNCTION public.allineamento_decidi(p_id uuid, p_azione text, p_metodo text DEFAULT NULL::text, p_importo numeric DEFAULT NULL::numeric, p_al date DEFAULT NULL::date, p_risposta text DEFAULT NULL::text, p_tipo text DEFAULT NULL::text, p_dal date DEFAULT NULL::date, p_slot_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v allineamento_proposte; v_met text; v_tipo text; v_dal date; v_al date; v_imp numeric;
  r jsonb; v_pag abbonamenti_pagamenti; v_isc iscrizioni_minori; v_esito text; v_lbl text;
begin
  if not public.is_segreteria() then raise exception 'Permesso negato: solo segreteria'; end if;
  select * into v from allineamento_proposte where id = p_id for update;
  if not found then raise exception 'Voce non trovata'; end if;
  if v.stato <> 'aperta' then raise exception 'Questa voce e'' gia'' chiusa (%)', v.stato; end if;

  v_tipo := coalesce(nullif(p_tipo,''), v.tipo_abbonamento);
  v_met  := lower(coalesce(nullif(p_metodo,''), v.metodo));
  if v_met = 'bancomat' then v_met := 'pos'; end if;
  if v_met is not null and v_met not in ('contanti','pos','bonifico') then
    raise exception 'Metodo non valido: contanti, bancomat o bonifico';
  end if;
  select label into v_lbl from abbonamenti_tipi where tipo = v_tipo;

  -- ---------- REGISTRA: crea l'abbonamento pagato adesso ----------
  if p_azione = 'registra' then
    if v.categoria = 'errore_elenco' then raise exception 'Questa voce riguarda il tuo foglio: correggilo e premi HO CORRETTO IL FOGLIO'; end if;
    if v.persona_id is null then raise exception 'La persona non e'' nel portale: prima inseriscila (Inserisci contatto)'; end if;
    if v_tipo is null then raise exception 'Scegli il tipo di abbonamento'; end if;
    v_dal := coalesce(p_dal, v.dal);
    v_al  := coalesce(p_al, v.al);
    v_imp := coalesce(p_importo, v.importo);
    if v_dal is null then raise exception 'Scrivi da quando vale'; end if;
    if v_al  is null then raise exception 'Scrivi fino a quando vale'; end if;
    if v_imp is null then raise exception 'Scrivi l''importo'; end if;
    if v_met is null then raise exception 'Scegli come ha pagato: contanti, bancomat o bonifico'; end if;

    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and tipo_abbonamento = v_tipo and dal = v_dal and al = v_al limit 1;
    if found then
      update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, deciso_da=auth.uid(), deciso_il=now(),
             risposta=coalesce(p_risposta,risposta), esito='Era gia'' registrato nel portale: nessun doppione'
       where id = p_id;
      return jsonb_build_object('success',true,'gia_registrato',true,'pagamento_id',v_pag.id,
        'esito','Era già registrato nel portale: nessun doppione');
    end if;

    -- 29 ott: i giorni del corso scelti nella finestra (vuoto = null: per un rinnovo restano quelli che ha)
    r := public.registra_abbonamento(v.persona_id, v_tipo, nullif(p_slot_ids, '{}'::uuid[]), v_dal, v_al, v_imp, v_met,
           'Console allineamento — notte ' || to_char(v.notte,'DD/MM/YYYY') || ' riga ' || v.n);
    v_esito := 'Registrato: ' || coalesce(v_lbl, v_tipo) || ' ' || to_char(v_dal,'DD/MM') || '–' || to_char(v_al,'DD/MM')
               || ', ' || trim(to_char(v_imp,'FM999990.00')) || ' € ' || case v_met when 'pos' then 'bancomat' else v_met end;
    update allineamento_proposte
       set stato='registrata', pagamento_id=(r->>'pagamento_id')::uuid, tipo_abbonamento=v_tipo, dal=v_dal, al=v_al,
           importo=v_imp, metodo=v_met, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito
     where id = p_id;
    return r || jsonb_build_object('esito', v_esito);

  -- ---------- PAGATO: il pagamento c'e' ma senza metodo / iscrizione non pagata ----------
  elsif p_azione = 'pagato' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    if v_met is null then raise exception 'Scegli come ha pagato: contanti, bancomat o bonifico'; end if;
    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and (v_tipo is null or tipo_abbonamento = v_tipo) and metodo is null
     order by al desc, registrato_il desc limit 1;
    if not found then
      raise exception 'Nel portale non c''e'' un pagamento in attesa da segnare: usa REGISTRA per inserirlo';
    end if;
    update abbonamenti_pagamenti
       set metodo = v_met, importo_eur = coalesce(p_importo, importo_eur),
           note = concat_ws(E'\n', note, 'Segnato pagato dalla segreteria (console allineamento) il ' || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY'))
     where id = v_pag.id;
    update iscrizioni_minori set paid = true where id = v_pag.iscrizione_id;
    v_esito := 'Segnato pagato: ' || coalesce(v_lbl, v_pag.tipo_abbonamento) || ' ' || to_char(v_pag.dal,'DD/MM') || '–' || to_char(v_pag.al,'DD/MM')
               || ', ' || trim(to_char(coalesce(p_importo, v_pag.importo_eur),'FM999990.00')) || ' € ' || case v_met when 'pos' then 'bancomat' else v_met end;
    update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, metodo=v_met, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'pagamento_id',v_pag.id,'esito',v_esito);

  -- ---------- CORREGGI IMPORTO: l'importo nel portale e' sbagliato ----------
  elsif p_azione = 'correggi_importo' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    if p_importo is null or p_importo < 0 then raise exception 'Scrivi l''importo giusto'; end if;
    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and (v_tipo is null or tipo_abbonamento = v_tipo)
       and (v.dal is null or (dal <= v.dal and al >= v.dal))
     order by al desc, registrato_il desc limit 1;
    if not found then raise exception 'Non trovo il pagamento da correggere: usa REGISTRA'; end if;
    update abbonamenti_pagamenti
       set importo_eur = p_importo,
           metodo = coalesce(v_met, metodo),
           note = concat_ws(E'\n', note, 'Importo corretto dalla segreteria (console allineamento) il '
                  || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY') || ': era ' || trim(to_char(v_pag.importo_eur,'FM999990.00')) || ' €')
     where id = v_pag.id;
    if v_met is not null then update iscrizioni_minori set paid = true where id = v_pag.iscrizione_id; end if;
    v_esito := 'Importo corretto: ' || trim(to_char(v_pag.importo_eur,'FM999990.00')) || ' € → ' || trim(to_char(p_importo,'FM999990.00')) || ' €';
    update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, importo=p_importo, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'pagamento_id',v_pag.id,'esito',v_esito);

  -- ---------- CHIUDI: non frequenta piu' ----------
  elsif p_azione = 'chiudi' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    select * into v_isc from iscrizioni_minori
     where persona_id = v.persona_id and status = 'attiva' and (v_tipo is null or tipo_abbonamento = v_tipo)
     order by data_fine desc nulls first limit 1;
    if not found then raise exception 'Non trovo un abbonamento attivo da chiudere'; end if;
    update iscrizioni_minori
       set status = 'terminata',
           note = concat_ws(E'\n', note, 'Chiuso dalla segreteria (console allineamento) il '
                  || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY') || coalesce(': ' || nullif(trim(p_risposta),''), ''))
     where id = v_isc.id;
    v_esito := 'Chiuso: ' || coalesce((select label from abbonamenti_tipi where tipo = v_isc.tipo_abbonamento), v_isc.tipo_abbonamento) || ' non più attivo';
    update allineamento_proposte set stato='fatto', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'iscrizione_id',v_isc.id,'esito',v_esito);

  elsif p_azione = 'fatto' then
    update allineamento_proposte set stato='fatto', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=coalesce(esito,'Sistemato') where id = p_id;

  elsif p_azione = 'rispondi' then
    if coalesce(trim(p_risposta),'') = '' then raise exception 'Scrivi la risposta'; end if;
    update allineamento_proposte set stato='risposta', risposta=p_risposta,
           deciso_da=auth.uid(), deciso_il=now() where id = p_id;

  elsif p_azione = 'scarta' then
    update allineamento_proposte set stato='scartata', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now() where id = p_id;

  else
    raise exception 'Azione % non valida', p_azione;
  end if;

  return jsonb_build_object('success', true, 'azione', p_azione);
end $function$;

-- permessi come la firma vecchia: niente PUBLIC né anon (Supabase li darebbe in automatico a una funzione nuova)
REVOKE ALL ON FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date, uuid[]) TO authenticated, service_role;
-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- 2. "Cambia giorni": la segreteria può cambiare anche QUANTI giorni
--    (caso Marina Ungari, Corso Bambini: lun+mer per errore, fa solo il mercoledì)
--    Via la guardia "stesso numero di giorni". Restano: solo segreteria, abbonamento attivo, tipo con
--    giorni, almeno un giorno, slot del tipo giusto e attivi, capienza. Importo, scadenza, pagato e
--    abbonamenti_pagamenti NON si toccano: la segreteria sa cosa è stato pagato.
--    CREATE OR REPLACE: stessa firma, i permessi restano.
-- ═══════════════════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.cambia_giorni_abbonamento(p_iscrizione_id uuid, p_slot_ids uuid[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_isc iscrizioni_minori; t abbonamenti_tipi;
  v_sid uuid; v_slot record; v_occ int;
  v_vecchi uuid[]; v_nuovi uuid[];
  v_txt_vecchi text; v_txt_nuovi text; v_riga text;
  g text[] := ARRAY['lun','mar','mer','gio','ven','sab','dom'];
BEGIN
  IF NOT is_segreteria_piena() THEN RAISE EXCEPTION 'Permesso negato: solo segreteria'; END IF;

  SELECT * INTO v_isc FROM iscrizioni_minori WHERE id = p_iscrizione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento % non trovato', p_iscrizione_id; END IF;
  IF v_isc.status <> 'attiva' THEN RAISE EXCEPTION 'L''abbonamento non è attivo: non si possono cambiare i giorni'; END IF;

  SELECT * INTO t FROM abbonamenti_tipi WHERE tipo = v_isc.tipo_abbonamento;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento senza tipo: sistemalo con "Abbonamento o corso"'; END IF;
  IF coalesce(array_length(t.slot_ammessi,1),0) = 0 THEN RAISE EXCEPTION '% non ha giorni da cambiare', t.label; END IF;

  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO v_nuovi FROM unnest(p_slot_ids) x WHERE x IS NOT NULL;
  IF coalesce(array_length(v_nuovi,1),0) = 0 THEN RAISE EXCEPTION 'Scegli almeno un giorno'; END IF;

  SELECT coalesce(array_agg(slot_id), '{}') INTO v_vecchi FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;

  IF v_nuovi @> v_vecchi AND v_vecchi @> v_nuovi THEN RAISE EXCEPTION 'I giorni sono già questi: nessun cambio'; END IF;
  -- 29 ott: tolta la guardia "stesso numero di giorni" (la segreteria è la verità: niente prezzo da ricalcolare)

  FOREACH v_sid IN ARRAY v_nuovi LOOP
    SELECT id, tipo_corso, fascia, status, capienza_max, giorno_settimana, ora_inizio INTO v_slot
      FROM corsi_attivi_settimanali WHERE id = v_sid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Giorno/slot % non trovato', v_sid; END IF;
    IF v_slot.status <> 'attivo' THEN RAISE EXCEPTION 'Il giorno % ore % non è attivo', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'); END IF;
    IF NOT (v_slot.tipo_corso||'/'||v_slot.fascia = ANY(t.slot_ammessi) OR v_slot.tipo_corso||'/*' = ANY(t.slot_ammessi)) THEN
      RAISE EXCEPTION 'Il giorno % ore % non fa parte di %', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'), t.label;
    END IF;
    IF v_slot.capienza_max IS NOT NULL AND NOT (v_sid = ANY(v_vecchi)) THEN
      SELECT count(*) INTO v_occ FROM iscrizioni_minori_slot ims JOIN iscrizioni_minori im ON im.id = ims.iscrizione_id
       WHERE ims.slot_id = v_sid AND im.status = 'attiva' AND im.id <> p_iscrizione_id;
      IF v_occ >= v_slot.capienza_max THEN
        RAISE EXCEPTION 'Pieno (%/%): % ore %', v_occ, v_slot.capienza_max, g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI');
      END IF;
    END IF;
  END LOOP;

  SELECT coalesce(string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio), 'nessuno')
    INTO v_txt_vecchi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_vecchi);
  SELECT string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio)
    INTO v_txt_nuovi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_nuovi);

  -- tipo fermo PRIMA di toccare gli slot (il trigger su INSERT ricalcola solo se tipo_da_slot)
  UPDATE iscrizioni_minori SET tipo_da_slot = false WHERE id = p_iscrizione_id;

  DELETE FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;
  INSERT INTO iscrizioni_minori_slot (iscrizione_id, slot_id) SELECT p_iscrizione_id, unnest(v_nuovi);

  v_riga := '['||to_char(CURRENT_DATE,'DD/MM/YYYY')||' giorni cambiati: '||v_txt_vecchi||' → '||v_txt_nuovi
            ||CASE WHEN nullif(trim(p_note),'') IS NOT NULL THEN ' · '||trim(p_note) ELSE '' END||']';
  UPDATE iscrizioni_minori SET note = concat_ws(E'\n', note, v_riga) WHERE id = p_iscrizione_id;

  RETURN jsonb_build_object('success', true, 'iscrizione_id', p_iscrizione_id, 'tipo', t.tipo, 'label', t.label,
    'prima', v_txt_vecchi, 'dopo', v_txt_nuovi, 'scadenza', v_isc.data_fine);
END $function$;
-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- 3. Compenso a percentuale: Marco Mellozzini su Corso Expert Ragazzi e Corso Giovani KataClimb (18–24)
--    Decisione Marco 29 ott (con l'aggiornamento della stessa sera):
--    - quelle lezioni restano in agenda E nelle presenze (PRESENTE / ASSENTE / SOSTITUISCI, da confermare):
--      servono per le sostituzioni. Cambia solo il compenso: per Mello valgono 0 € a lezione.
--    - quota: 30% a Mellozzini, 70% all'Accademia, salvata come dato (slot_piano_staff.percentuale).
--    - se Mello è ASSENTE e lo sostituisce qualcuno, il sostituto è pagato con la sua tariffa normale
--      (compenso_tipo 'lezione', NON eredita la percentuale) e quella cifra si scala dal 30% di Mello.
--    Conto di Mello = 30% × (incassi del mese degli allievi di Expert e Giovani − iscrizioni annuali da 40 €)
--                     − pagato ai sostituti sulle sue lezioni a percentuale.
--    Decisioni definitive Marco 30 ott 2026 (sostituiscono le precedenti):
--    - il 30% si calcola sui soldi realmente incassati dagli allievi di Expert e Giovani, iscrizione
--      annuale esclusa, divisi in parti uguali sui mesi che il pagamento copre (trimestrale 270 € pagato
--      il 5/10 = 90 ott + 90 nov + 90 dic; centesimi che avanzano sul primo mese). Gli sconti normali
--      (famiglia, secondo figlio…) restano dentro: si conta quello che è entrato (Matteo Parenti: 243 €).
--      Un pagamento non ancora fatto non entra finché non viene pagato; poi entra sui mesi che copre.
--    - Davide Costantini paga 90 € al mese (non è un quadrimestrale): contano solo i mesi pagati, 90 €
--      ciascuno, sul mese che coprono.
--    - unica eccezione, Tommaso Pescetelli: per il conto di Mello è un allievo normale, 90 € per ogni
--      mese in cui è iscritto all'Expert, senza il suo sconto.
--    - settembre 2026 è chiuso: Mello è già stato pagato a mano, più 200 € regalati che restano a lui e
--      non si scalano da nessun mese. La percentuale parte dal 1/10/2026 (slot_piano_staff.percentuale_dal).
--    Eccezioni salvate come dato in compenso_percentuale_eccezioni (3f); il conto è in 3g.
--
--    Perché la quota sta su slot_piano_staff e non su tariffe_staff: tariffe_staff ha una riga per
--    persona (chiave user_id) e vale per tutte le sue lezioni; la percentuale invece vale per persona
--    E corso, che è esattamente la riga del piano (slot + persona, unica), dove sta già compenso_tipo.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

-- 3a. 'percentuale' ammesso in compenso_tipo; colonna della quota (obbligatoria se e solo se a percentuale)
ALTER TABLE public.slot_piano_staff DROP CONSTRAINT slot_piano_staff_compenso_tipo_check;
ALTER TABLE public.slot_piano_staff ADD CONSTRAINT slot_piano_staff_compenso_tipo_check
  CHECK (compenso_tipo = ANY (ARRAY['lezione'::text, 'ora'::text, 'percentuale'::text]));
ALTER TABLE public.impegni_staff DROP CONSTRAINT impegni_staff_compenso_tipo_chk;
ALTER TABLE public.impegni_staff ADD CONSTRAINT impegni_staff_compenso_tipo_chk
  CHECK (compenso_tipo = ANY (ARRAY['lezione'::text, 'ora'::text, 'percentuale'::text]));

ALTER TABLE public.slot_piano_staff ADD COLUMN percentuale numeric;
COMMENT ON COLUMN public.slot_piano_staff.percentuale IS
  'Solo con compenso_tipo = percentuale: quota (in %) degli incassi del corso che va a questa persona (29 ott 2026: Mellozzini 30 su Expert e Giovani, 70 all''Accademia).';
ALTER TABLE public.slot_piano_staff ADD CONSTRAINT slot_piano_staff_percentuale_check
  CHECK ((compenso_tipo = 'percentuale') = (percentuale IS NOT NULL) AND (percentuale IS NULL OR (percentuale > 0 AND percentuale <= 100)));

ALTER TABLE public.slot_piano_staff ADD COLUMN percentuale_dal date;
COMMENT ON COLUMN public.slot_piano_staff.percentuale_dal IS
  'Solo con compenso_tipo = percentuale: primo giorno del primo mese in cui vale la quota. I mesi prima non entrano nel conto (30 ott 2026: Mellozzini dal 1/10/2026, settembre saldato a mano).';
ALTER TABLE public.slot_piano_staff ADD CONSTRAINT slot_piano_staff_percentuale_dal_check
  CHECK (percentuale_dal IS NULL OR compenso_tipo = 'percentuale');

-- 3b. i due posti di Mello nel piano e tutte le sue lezioni su quei due slot (passate e future)
UPDATE public.slot_piano_staff
   SET compenso_tipo = 'percentuale', percentuale = 30, percentuale_dal = '2026-10-01',
       note = concat_ws(' · ', note, 'a percentuale 30% dal 1/10/2026, settembre saldato a mano (Marco, 29–30/10/2026)')
 WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b'   -- Marco Mellozzini
   AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e',  -- Corso Expert Ragazzi, mercoledì 18:00
                   '895b3610-a95c-4167-8eca-ed7cd704e92c')  -- Corso Giovani KataClimb (18–24), giovedì 21:00
   AND ruolo = 'conduce';

UPDATE public.impegni_staff
   SET compenso_tipo = 'percentuale', updated_at = now()
 WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b'
   AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e', '895b3610-a95c-4167-8eca-ed7cd704e92c')
   AND tipo = 'lezione' AND compenso_tipo <> 'percentuale';

-- 3c. una regola sola per chi entra su una lezione: la percentuale resta a chi ce l'ha nel piano per
--     quello slot; chi sostituisce un titolare a percentuale è pagato a lezione (non eredita la quota).
CREATE OR REPLACE FUNCTION public._compenso_tipo_staff(p_user uuid, p_slot uuid, p_base text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
           when exists (select 1 from public.slot_piano_staff
                         where slot_id = p_slot and user_id = p_user and compenso_tipo = 'percentuale') then 'percentuale'
           when p_base = 'percentuale' then 'lezione'
           else p_base
         end;
$function$;
REVOKE ALL ON FUNCTION public._compenso_tipo_staff(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._compenso_tipo_staff(uuid, uuid, text) TO authenticated, service_role;

-- genera_impegni_lezioni: il titolare copia il suo compenso_tipo dal piano (resta 'percentuale');
-- il sostituto da piano passa dalla regola sopra
CREATE OR REPLACE FUNCTION public.genera_impegni_lezioni(p_giorni integer DEFAULT 28)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE n integer; n2 integer;
BEGIN
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, compenso_tipo, da_piano, note)
  SELECT p.user_id, 'lezione', c.id, d::date, c.ora_inizio, c.ora_fine, p.ruolo, 'previsto', p.compenso_tipo, true, 'piano fisso'
    FROM slot_piano_staff p
    JOIN corsi_attivi_settimanali c ON c.id = p.slot_id AND c.status = 'attivo' AND c.data_evento IS NULL
    CROSS JOIN generate_series(CURRENT_DATE, CURRENT_DATE + p_giorni, interval '1 day') d
   WHERE p.attivo AND extract(isodow FROM d) = c.giorno_settimana
     AND NOT public.staff_indisponibile(p.user_id, d::date, c.ora_inizio, c.ora_fine)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, compenso_tipo, da_piano, note)
  SELECT p.sostituto_user_id, 'lezione', c.id, d::date, c.ora_inizio, c.ora_fine, p.ruolo, 'previsto',
         public._compenso_tipo_staff(p.sostituto_user_id, c.id, p.compenso_tipo), true, 'sostituto da piano (titolare non disponibile)'
    FROM slot_piano_staff p
    JOIN corsi_attivi_settimanali c ON c.id = p.slot_id AND c.status = 'attivo' AND c.data_evento IS NULL
    CROSS JOIN generate_series(CURRENT_DATE, CURRENT_DATE + p_giorni, interval '1 day') d
   WHERE p.attivo AND p.sostituto_user_id IS NOT NULL AND extract(isodow FROM d) = c.giorno_settimana
     AND public.staff_indisponibile(p.user_id, d::date, c.ora_inizio, c.ora_fine)
     AND NOT public.staff_indisponibile(p.sostituto_user_id, d::date, c.ora_inizio, c.ora_fine)
     AND NOT EXISTS (SELECT 1 FROM impegni_staff x WHERE x.user_id = p.user_id AND x.slot_id = c.id AND x.data = d::date)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  RETURN n + n2;
END $function$;

-- trigger del sostituto automatico (titolare segnato assente/ritirato)
CREATE OR REPLACE FUNCTION public.tg_sostituto_da_piano()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE p slot_piano_staff;
BEGIN
  IF coalesce(current_setting('kc.no_sostituto', true), '0') = '1' THEN
    RETURN NEW;
  END IF;
  IF NEW.tipo = 'lezione' AND NEW.stato IN ('ritirato','assente') AND OLD.stato NOT IN ('ritirato','assente') THEN
    SELECT * INTO p FROM slot_piano_staff WHERE slot_id = NEW.slot_id AND user_id = NEW.user_id AND attivo AND sostituto_user_id IS NOT NULL;
    IF FOUND AND NOT public.staff_indisponibile(p.sostituto_user_id, NEW.data, NEW.ora_inizio, NEW.ora_fine) THEN
      INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, compenso_tipo, da_piano, note)
      VALUES (p.sostituto_user_id, 'lezione', NEW.slot_id, NEW.data, NEW.ora_inizio, NEW.ora_fine, p.ruolo, 'previsto',
              public._compenso_tipo_staff(p.sostituto_user_id, NEW.slot_id, p.compenso_tipo), true, 'sostituto da piano')
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END $function$;

-- SOSTITUISCI: il sostituto non eredita la percentuale (se torna il titolare a percentuale, la riprende)
CREATE OR REPLACE FUNCTION public.sostituisci_istruttore(p_impegno_id uuid, p_nuovo_user uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r public.impegni_staff;
  v_seg boolean := public.is_segreteria();
  v_stato text;
  v_comp text;
  v_id uuid;
begin
  select * into r from public.impegni_staff where id = p_impegno_id;
  if not found then raise exception 'impegno non trovato'; end if;
  if r.tipo <> 'lezione' then raise exception 'si sostituisce solo su una lezione'; end if;
  if r.user_id <> auth.uid() and not v_seg then raise exception 'solo il titolare o la segreteria'; end if;
  if r.user_id = p_nuovo_user then raise exception 'e'' la stessa persona'; end if;
  if r.data < current_date and not v_seg then raise exception 'lezione passata: la registra la segreteria'; end if;
  if not exists (select 1 from public.profile_data where user_id = p_nuovo_user and staff_role like 'staff%') then
    raise exception 'la persona scelta non e'' staff';
  end if;
  if r.data >= current_date and public.staff_indisponibile(p_nuovo_user, r.data, r.ora_inizio, r.ora_fine) then
    raise exception 'La persona scelta ha segnato che quel giorno non è disponibile: scegli un altro.';
  end if;

  v_comp := case when exists (select 1 from public.profile_data where user_id = p_nuovo_user and staff_role = 'staff_assistente')
                 then 'ora' else public._compenso_tipo_staff(p_nuovo_user, r.slot_id, r.compenso_tipo) end;
  v_stato := case when r.data < current_date then 'presente' else 'previsto' end;

  perform set_config('kc.no_sostituto', '1', true);
  update public.impegni_staff
     set stato = case when r.user_id = auth.uid() then 'ritirato' else 'assente' end,
         updated_at = now(),
         note = coalesce(note || ' · ', '') || 'sostituito'
   where id = r.id;

  insert into public.impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato,
                                    compenso_tipo, da_piano, presenza_inizio, segnato_da, note)
  values (p_nuovo_user, 'lezione', r.slot_id, r.data, r.ora_inizio, r.ora_fine, r.ruolo, v_stato,
          v_comp, false, case when v_stato = 'presente' then (r.data + r.ora_inizio) end, auth.uid(),
          coalesce(p_note, 'sostituzione'))
  on conflict (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set stato = excluded.stato, ruolo = excluded.ruolo, compenso_tipo = excluded.compenso_tipo,
                segnato_da = excluded.segnato_da, note = excluded.note, updated_at = now()
  returning id into v_id;
  perform set_config('kc.no_sostituto', '0', true);

  return jsonb_build_object('ok', true, 'sostituito', r.id, 'nuovo_impegno', v_id, 'stato', v_stato);
end $function$;

-- "mi segno" / la segreteria segna qualcuno: su un suo slot a percentuale resta a percentuale
-- (prima l'ON CONFLICT lo avrebbe riportato a 'lezione')
CREATE OR REPLACE FUNCTION public.impegno_mi_segno(p_tipo text, p_slot_id uuid DEFAULT NULL::uuid, p_data date DEFAULT NULL::date, p_ora_inizio time without time zone DEFAULT NULL::time without time zone, p_ora_fine time without time zone DEFAULT NULL::time without time zone, p_ruolo text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := coalesce(p_user_id, auth.uid()); v_id uuid; v_data date; v_ini time; v_fin time; v_ruolo text; v_n int; v_comp text := 'lezione';
begin
  if not public.is_staff() then raise exception 'solo staff'; end if;
  if v_user <> auth.uid() and not public.is_segreteria() then raise exception 'solo la segreteria segna gli altri'; end if;
  if p_tipo = 'lezione' then
    if p_slot_id is null then raise exception 'slot mancante'; end if;
    select coalesce(data_evento, p_data), ora_inizio, ora_fine into v_data, v_ini, v_fin from public.corsi_attivi_settimanali where id = p_slot_id;
    if v_data is null then raise exception 'slot senza data: indica p_data'; end if;
    v_ruolo := coalesce(p_ruolo, 'supporto');
    if v_ruolo = 'assistente' then v_ruolo := 'supporto'; v_comp := 'ora'; end if;
    if v_ruolo not in ('conduce','supporto') then raise exception 'ruolo non valido per una lezione'; end if;
    if exists (select 1 from public.profile_data where user_id = v_user and staff_role = 'staff_assistente') then v_comp := 'ora'; end if;
    if v_comp <> 'ora' then v_comp := public._compenso_tipo_staff(v_user, p_slot_id, v_comp); end if;
  elsif p_tipo = 'monitor' then
    if p_data is null or p_ora_inizio is null or p_ora_fine is null then raise exception 'data e orario obbligatori per il turno monitor'; end if;
    v_data := p_data; v_ini := p_ora_inizio; v_fin := p_ora_fine; v_ruolo := 'monitor';
  else
    raise exception 'tipo non valido';
  end if;
  if v_data < current_date and not public.is_segreteria() then raise exception 'data nel passato'; end if;
  if public.staff_indisponibile(v_user, v_data, v_ini, v_fin) then
    raise exception 'Il %/% ha segnato che non è disponibile: se adesso può esserci, prima togli il "non ci sono".',
      extract(day from v_data)::int, extract(month from v_data)::int;
  end if;

  insert into public.impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, segnato_da, note, compenso_tipo)
  values (v_user, p_tipo, case when p_tipo='lezione' then p_slot_id end, v_data, v_ini, v_fin, v_ruolo, auth.uid(), p_note, v_comp)
  on conflict (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set ruolo = excluded.ruolo, compenso_tipo = excluded.compenso_tipo, note = coalesce(excluded.note, impegni_staff.note),
                stato = case when impegni_staff.stato = 'ritirato' then 'previsto' else impegni_staff.stato end,
                segnato_da = excluded.segnato_da, updated_at = now()
  returning id into v_id;

  select count(*) into v_n from public.impegni_staff where data = v_data and ora_inizio = v_ini and stato <> 'ritirato'
    and coalesce(slot_id,'00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_slot_id,'00000000-0000-0000-0000-000000000000'::uuid);
  return jsonb_build_object('ok', true, 'id', v_id, 'data', v_data, 'ruolo', v_ruolo, 'compenso_tipo', v_comp, 'segnati', v_n);
end $function$;

-- appello dal calendario: chi fa l'appello sulla lezione di un titolare a percentuale lo segna assente
-- come un titolare a lezione; se l'appello lo fa il titolare a percentuale resta a percentuale
CREATE OR REPLACE FUNCTION public._staff_presenza_da_appello(p_slot uuid, p_data date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  c      public.corsi_attivi_settimanali;
  r      public.impegni_staff;
  v_min  int;
  v_prima boolean;
begin
  if v_uid is null or p_slot is null or p_data is null then return; end if;
  select staff_role into v_role from public.profile_data where user_id = v_uid;
  if coalesce(v_role,'') not in ('staff_istruttore_tutor','staff_istruttore_sr','staff_istruttore_jr') then return; end if;
  select * into c from public.corsi_attivi_settimanali where id = p_slot;
  if not found or c.tipo_corso = 'monitor' then return; end if;
  v_prima := c.tipo_corso like 'prima_lezione%';

  select * into r from public.impegni_staff
   where user_id = v_uid and tipo = 'lezione' and slot_id = p_slot and data = p_data;

  if found and r.stato = 'presente' then return; end if;

  if found then
    update public.impegni_staff
       set stato = 'presente', presenza_inizio = coalesce(presenza_inizio, now()), updated_at = now(),
           note = case when r.stato in ('ritirato','assente')
                       then coalesce(r.note || ' · ', '') || 'presente dal calendario' else r.note end
     where id = r.id;
    if r.stato = 'previsto' then return; end if;
  else
    insert into public.impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato,
                                      compenso_tipo, da_piano, presenza_inizio, segnato_da, note)
    values (v_uid, 'lezione', p_slot, p_data, c.ora_inizio, c.ora_fine, 'conduce', 'presente',
            case when v_prima then 'ora' else public._compenso_tipo_staff(v_uid, p_slot, 'lezione') end, false, now(), v_uid,
            'sostituzione registrata dal calendario');
  end if;

  select istruttori_min into v_min from public.slot_copertura where slot_id = p_slot;
  if coalesce(v_min, 1) = 1 then
    perform set_config('kc.no_sostituto', '1', true);
    update public.impegni_staff
       set stato = 'assente', updated_at = now(),
           note = coalesce(note || ' · ', '') || 'sostituito (calendario)'
     where slot_id = p_slot and data = p_data and tipo = 'lezione' and stato = 'previsto'
       and user_id <> v_uid and (compenso_tipo in ('lezione','percentuale') or v_prima);
    perform set_config('kc.no_sostituto', '0', true);
  end if;
end $function$;

-- 4. (qui perché le viste sotto la usano) Prima Lezione dentro un corso dello stesso istruttore
--    Decisione Marco: se un istruttore è in agenda su un corso e nella stessa fascia gli si mette una
--    Prima Lezione (Adulti, Bambini, Ragazzi, Genitori: tutte), la Prima Lezione NON si paga: è già
--    pagato dal corso. Il corso conta anche se è a percentuale (l'istruttore è comunque già lì).
--    Il corso deve essere previsto o presente: se sul corso è ASSENTE, il corso non lo paga e la
--    Prima Lezione si paga come sempre (la consegna diceva solo "non ritirato": scelta più prudente).
CREATE OR REPLACE FUNCTION public._prima_dentro_corso(p_impegno uuid, p_user uuid, p_data date, p_ini time without time zone, p_fin time without time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
      from public.impegni_staff o
      join public.corsi_attivi_settimanali oc on oc.id = o.slot_id
     where o.user_id = p_user and o.data = p_data and o.id <> p_impegno
       and o.tipo = 'lezione' and o.stato in ('previsto','presente')
       and oc.tipo_corso not like 'prima_lezione%'
       and o.ora_inizio < p_fin and o.ora_fine > p_ini);
$function$;
-- anche anon: la usa v_compenso_lezioni, che anon può leggere (righe filtrate a zero); dice solo vero/falso
REVOKE ALL ON FUNCTION public._prima_dentro_corso(uuid, uuid, date, time without time zone, time without time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._prima_dentro_corso(uuid, uuid, date, time without time zone, time without time zone) TO anon, authenticated, service_role;

-- 3d. viste (con il punto 4 dentro)
-- v_compenso_lezioni: a percentuale = 0 € a lezione; da_confermare resta com'è (serve per le sostituzioni).
-- Punto 4: Prima Lezione dentro un corso dello stesso istruttore = 0 € e niente da confermare.
-- In fondo le colonne nuove percentuale (la quota del piano, solo sulle righe a percentuale) e dentro_corso.
CREATE OR REPLACE VIEW public.v_compenso_lezioni AS
 SELECT i.id AS impegno_id,
    i.user_id,
    COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(pe.nome, ''::text) || ' '::text) || COALESCE(pe.cognome, ''::text)), ''::text), '—'::text) AS persona,
    i.data,
    i.slot_id,
    c.tipo_corso,
    c.fascia,
    i.ora_inizio,
    i.ora_fine,
    i.ruolo,
    i.compenso_tipo,
    i.stato,
    round(EXTRACT(epoch FROM i.ora_fine - i.ora_inizio) / 3600.0, 2) AS ore,
        CASE
            WHEN dc.dentro_corso THEN 0::numeric
            WHEN i.stato = 'presente'::text THEN
            CASE
                WHEN c.tipo_corso ~~ 'prima_lezione%'::text THEN round(EXTRACT(epoch FROM i.ora_fine - i.ora_inizio) / 3600.0 *
                CASE
                    WHEN (EXISTS ( SELECT 1
                       FROM prenotazioni_prima_lezione pp
                      WHERE pp.slot_id = i.slot_id AND pp.data_lezione = i.data AND pp.stato = 'fatto'::text)) THEN 15
                    ELSE 5
                END::numeric, 2)
                WHEN i.compenso_tipo = 'percentuale'::text THEN 0::numeric
                WHEN i.compenso_tipo = 'lezione'::text THEN COALESCE(t.euro_lezione, 15::numeric)
                ELSE round(EXTRACT(epoch FROM i.ora_fine - i.ora_inizio) / 3600.0 * COALESCE(t.euro_ora, 5::numeric), 2)
            END
            ELSE 0::numeric
        END AS euro,
    i.stato = 'previsto'::text AND i.data < CURRENT_DATE AND NOT dc.dentro_corso AS da_confermare,
    sp.percentuale,
    dc.dentro_corso
   FROM impegni_staff i
     JOIN corsi_attivi_settimanali c ON c.id = i.slot_id
     CROSS JOIN LATERAL ( SELECT c.tipo_corso ~~ 'prima_lezione%'::text AND _prima_dentro_corso(i.id, i.user_id, i.data, i.ora_inizio, i.ora_fine) AS dentro_corso) dc
     LEFT JOIN tariffe_staff t ON t.user_id = i.user_id
     LEFT JOIN profile_data pd ON pd.user_id = i.user_id
     LEFT JOIN persone pe ON pe.id = pd.persona_id
     LEFT JOIN slot_piano_staff sp ON sp.slot_id = i.slot_id AND sp.user_id = i.user_id AND i.compenso_tipo = 'percentuale'::text
  WHERE i.tipo = 'lezione'::text AND i.stato <> 'ritirato'::text AND (i.user_id = auth.uid() OR is_segreteria());

-- v_costi_staff_mese: le lezioni a percentuale non contano tra le "lezioni corsi" pagate a lezione;
-- in fondo la colonna nuova lezioni_percentuale (fatte, presenti). Punto 4: la Prima Lezione dentro
-- un corso non conta tra le Prime Lezioni pagate.
CREATE OR REPLACE VIEW public.v_costi_staff_mese AS
 WITH l AS (
         SELECT x.user_id,
            x.persona,
            date_trunc('month'::text, x.data::timestamp with time zone)::date AS mese,
            count(*) FILTER (WHERE x.stato = 'presente'::text AND x.tipo_corso !~~ 'prima_lezione%'::text AND x.compenso_tipo <> 'percentuale'::text) AS lezioni_corsi,
            COALESCE(sum(x.euro) FILTER (WHERE x.tipo_corso !~~ 'prima_lezione%'::text), 0::numeric) AS euro_corsi,
            count(*) FILTER (WHERE x.stato = 'presente'::text AND x.tipo_corso ~~ 'prima_lezione%'::text AND NOT x.dentro_corso) AS prime_lezioni,
            COALESCE(sum(x.euro) FILTER (WHERE x.tipo_corso ~~ 'prima_lezione%'::text), 0::numeric) AS euro_prime,
            count(*) FILTER (WHERE x.da_confermare) AS da_confermare,
            count(*) FILTER (WHERE x.stato = 'assente'::text) AS assenze,
            count(*) FILTER (WHERE x.note_sost) AS sostituzioni,
            count(*) FILTER (WHERE x.stato = 'presente'::text AND x.compenso_tipo = 'percentuale'::text) AS lezioni_percentuale
           FROM ( SELECT v.impegno_id,
                    v.user_id,
                    v.persona,
                    v.data,
                    v.slot_id,
                    v.tipo_corso,
                    v.fascia,
                    v.ora_inizio,
                    v.ora_fine,
                    v.ruolo,
                    v.compenso_tipo,
                    v.stato,
                    v.ore,
                    v.euro,
                    v.da_confermare,
                    v.dentro_corso,
                    s.note ~~* '%sostitu%'::text AND s.user_id = v.user_id AND s.stato = 'presente'::text AS note_sost
                   FROM v_compenso_lezioni v
                     JOIN impegni_staff s ON s.id = v.impegno_id) x
          GROUP BY x.user_id, x.persona, (date_trunc('month'::text, x.data::timestamp with time zone)::date)
        ), m AS (
         SELECT v_compenso_monitor_mese.user_id,
            v_compenso_monitor_mese.monitor,
            v_compenso_monitor_mese.mese,
            v_compenso_monitor_mese.ore,
            v_compenso_monitor_mese.compenso_eur
           FROM v_compenso_monitor_mese
        )
 SELECT COALESCE(l.user_id, m.user_id) AS user_id,
    COALESCE(l.persona, m.monitor) AS persona,
    COALESCE(l.mese, m.mese) AS mese,
    COALESCE(l.lezioni_corsi, 0::bigint) AS lezioni_corsi,
    COALESCE(l.euro_corsi, 0::numeric) AS euro_corsi,
    COALESCE(l.prime_lezioni, 0::bigint) AS prime_lezioni,
    COALESCE(l.euro_prime, 0::numeric) AS euro_prime,
    COALESCE(m.ore, 0::numeric) AS ore_monitor,
    COALESCE(m.compenso_eur, 0::numeric) AS euro_monitor,
    COALESCE(l.euro_corsi, 0::numeric) + COALESCE(l.euro_prime, 0::numeric) + COALESCE(m.compenso_eur, 0::numeric) AS totale,
    COALESCE(l.sostituzioni, 0::bigint) AS sostituzioni,
    COALESCE(l.assenze, 0::bigint) AS assenze,
    COALESCE(l.da_confermare, 0::bigint) AS da_confermare,
    COALESCE(l.lezioni_percentuale, 0::bigint) AS lezioni_percentuale
   FROM l
     FULL JOIN m ON m.user_id = l.user_id AND m.mese = l.mese
  WHERE COALESCE(l.user_id, m.user_id) = auth.uid() OR is_segreteria();

-- v_copertura_lezioni: chi conduce a percentuale è un istruttore (prima non sarebbe contato: "lezione scoperta")
CREATE OR REPLACE VIEW public.v_copertura_lezioni AS
 SELECT c.id AS slot_id,
    d.d::date AS data,
    c.tipo_corso,
    c.fascia,
    c.ora_inizio,
    c.ora_fine,
    sc.istruttori_min,
    sc.assistenti_min,
    count(i.id) FILTER (WHERE i.compenso_tipo = ANY (ARRAY['lezione'::text, 'percentuale'::text]) OR c.tipo_corso ~~ 'prima_lezione%'::text) AS istruttori,
    count(i.id) FILTER (WHERE i.compenso_tipo = 'ora'::text AND c.tipo_corso !~~ 'prima_lezione%'::text) AS assistenti,
    count(i.id) FILTER (WHERE i.compenso_tipo = ANY (ARRAY['lezione'::text, 'percentuale'::text]) OR c.tipo_corso ~~ 'prima_lezione%'::text) >= sc.istruttori_min AND count(i.id) FILTER (WHERE i.compenso_tipo = 'ora'::text AND c.tipo_corso !~~ 'prima_lezione%'::text) >= sc.assistenti_min AS coperta,
    ( SELECT rs.id
           FROM richieste_supporto rs
          WHERE rs.slot_id = c.id AND rs.data = d.d::date AND rs.stato = 'aperta'::text
         LIMIT 1) AS supporto_richiesto_id
   FROM slot_copertura sc
     JOIN corsi_attivi_settimanali c ON c.id = sc.slot_id AND c.status = 'attivo'::text AND c.data_evento IS NULL
     CROSS JOIN generate_series(CURRENT_DATE::timestamp with time zone, (CURRENT_DATE + 28)::timestamp with time zone, '1 day'::interval) d(d)
     LEFT JOIN impegni_staff i ON i.slot_id = c.id AND i.data = d.d::date AND i.tipo = 'lezione'::text AND (i.stato = ANY (ARRAY['previsto'::text, 'presente'::text]))
  WHERE EXTRACT(isodow FROM d.d) = c.giorno_settimana::numeric AND is_staff()
  GROUP BY c.id, d.d, c.tipo_corso, c.fascia, c.ora_inizio, c.ora_fine, sc.istruttori_min, sc.assistenti_min;
-- v_segreteria_da_sistemare: "lezione senza istruttore" conta anche chi conduce a percentuale.
-- Le lezioni a percentuale RESTANO in "Presenze da confermare" (aggiornamento Marco 29 ott).
-- Punto 4: la Prima Lezione dentro un corso dello stesso istruttore esce da "Presenze da confermare"
-- e non è più una "doppia lezione" (Prima Lezione + corso nella stessa ora è voluto, non un errore).
CREATE OR REPLACE VIEW public.v_segreteria_da_sistemare AS
 WITH imp AS (
         SELECT i.id,
            i.user_id,
            i.tipo,
            i.slot_id,
            i.data,
            i.ora_inizio,
            i.ora_fine,
            i.ruolo,
            i.stato,
            i.presenza_inizio,
            i.presenza_fine,
            i.turno_monitor_id,
            i.segnato_da,
            i.note,
            i.created_at,
            i.updated_at,
            i.compenso_tipo,
            i.da_piano,
            c.tipo_corso,
            c.fascia,
            COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(pe.nome, ''::text) || ' '::text) || COALESCE(pe.cognome, ''::text)), ''::text), '—'::text) AS persona,
            pd.staff_role
           FROM impegni_staff i
             JOIN corsi_attivi_settimanali c ON c.id = i.slot_id
             LEFT JOIN profile_data pd ON pd.user_id = i.user_id
             LEFT JOIN persone pe ON pe.id = pd.persona_id
          WHERE i.tipo = 'lezione'::text AND i.stato <> 'ritirato'::text
        )
 SELECT 1 AS ordine,
    'presenza_mancante'::text AS tipo,
    i.data,
    i.ora_inizio,
    i.persona,
    i.user_id,
    i.id AS impegno_id,
    NULL::uuid AS turno_id,
    i.slot_id,
    i.tipo_corso,
    i.fascia,
    'Lezione passata senza presenza: vale 0 € finché non confermi se c''era.'::text AS cosa,
    'PRESENTE · ASSENTE · SOSTITUISCI'::text AS azioni
   FROM imp i
  WHERE i.stato = 'previsto'::text AND i.data < CURRENT_DATE AND i.data >= (CURRENT_DATE - 60)
    AND NOT (i.tipo_corso ~~ 'prima_lezione%'::text AND _prima_dentro_corso(i.id, i.user_id, i.data, i.ora_inizio, i.ora_fine))
UNION ALL
 SELECT 2 AS ordine,
    'turno_da_chiudere'::text AS tipo,
    v.data,
    v.inizio::time without time zone AS ora_inizio,
    v.monitor AS persona,
    v.user_id,
    NULL::uuid AS impegno_id,
    v.turno_id,
    NULL::uuid AS slot_id,
    'monitor'::text AS tipo_corso,
    NULL::text AS fascia,
    'Turno di Sala con Monitor mai chiuso: vale 0 € finché non scrivi l''ora reale di fine.'::text AS cosa,
    'CHIUDI TURNO'::text AS azioni
   FROM v_compenso_turni_monitor v
  WHERE v.da_chiudere
UNION ALL
 SELECT 3 AS ordine,
    'ruolo_da_verificare'::text AS tipo,
    i.data,
    i.ora_inizio,
    i.persona,
    i.user_id,
    i.id AS impegno_id,
    NULL::uuid AS turno_id,
    i.slot_id,
    i.tipo_corso,
    i.fascia,
    'È un monitor: non è istruttore né assistente, sostituisce solo in casi estremi. È stato davvero un caso estremo? Se no, toglilo.'::text AS cosa,
    'TOGLI · CONFERMA'::text AS azioni
   FROM imp i
  WHERE i.staff_role = 'staff_monitor'::text AND (i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AND i.data >= (CURRENT_DATE - 60)
UNION ALL
 SELECT 4 AS ordine,
    'doppia_lezione'::text AS tipo,
    a.data,
    a.ora_inizio,
    a.persona,
    a.user_id,
    a.id AS impegno_id,
    NULL::uuid AS turno_id,
    a.slot_id,
    a.tipo_corso,
    a.fascia,
    ((('Segnata su due lezioni nello stesso orario ('::text || a.tipo_corso) || ' e '::text) || b.tipo_corso) || '): una delle due è sbagliata?'::text AS cosa,
    'TOGLI · SOSTITUISCI · CONFERMA'::text AS azioni
   FROM imp a
     JOIN imp b ON b.user_id = a.user_id AND b.data = a.data AND b.id <> a.id AND (LEAST(a.ora_fine, b.ora_fine) - GREATEST(a.ora_inizio, b.ora_inizio)) > '00:30:00'::interval AND (b.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AND a.id < b.id
  WHERE (a.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AND a.data >= (CURRENT_DATE - 60)
    AND (a.tipo_corso ~~ 'prima_lezione%'::text) = (b.tipo_corso ~~ 'prima_lezione%'::text)
UNION ALL
 SELECT 5 AS ordine,
    'lezione_scoperta'::text AS tipo,
    d.d::date AS data,
    c.ora_inizio,
    NULL::text AS persona,
    NULL::uuid AS user_id,
    NULL::uuid AS impegno_id,
    NULL::uuid AS turno_id,
    c.id AS slot_id,
    c.tipo_corso,
    c.fascia,
    ('Lezione senza istruttore'::text ||
        CASE
            WHEN sc.assistenti_min > 0 THEN ' o assistente'::text
            ELSE ''::text
        END) || ': chi la fa?'::text AS cosa,
    'AGGIUNGI STAFF'::text AS azioni
   FROM slot_copertura sc
     JOIN corsi_attivi_settimanali c ON c.id = sc.slot_id AND c.status = 'attivo'::text AND c.data_evento IS NULL
     CROSS JOIN generate_series(CURRENT_DATE::timestamp with time zone, (CURRENT_DATE + 7)::timestamp with time zone, '1 day'::interval) d(d)
  WHERE EXTRACT(isodow FROM d.d) = c.giorno_settimana::numeric AND NOT (EXISTS ( SELECT 1
           FROM slot_chiusure ch
          WHERE ch.slot_id = c.id AND ch.data = d.d::date)) AND ((( SELECT count(*) AS count
           FROM impegni_staff i
          WHERE i.slot_id = c.id AND i.data = d.d::date AND i.tipo = 'lezione'::text AND (i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AND (i.compenso_tipo = ANY (ARRAY['lezione'::text, 'percentuale'::text]) OR c.tipo_corso ~~ 'prima_lezione%'::text))) < sc.istruttori_min OR (( SELECT count(*) AS count
           FROM impegni_staff i
          WHERE i.slot_id = c.id AND i.data = d.d::date AND i.tipo = 'lezione'::text AND (i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AND i.compenso_tipo = 'ora'::text AND c.tipo_corso !~~ 'prima_lezione%'::text)) < sc.assistenti_min);

-- 3e. v_compenso_percentuale: il conto delle lezioni a percentuale, una riga per lezione (e per sostituto).
--     esito: fatta (il titolare c'era) · sostituita (c'era un altro a condurre: la sua cifra si scala) ·
--     da_confermare · prevista · non_fatta. euro_da_scalare = quanto è stato pagato al sostituto.
--     La cifra del sostituto è la sua tariffa normale, la stessa regola di v_compenso_lezioni
--     (calcolata qui perché v_compenso_lezioni a Mello mostra solo le sue righe).
CREATE VIEW public.v_compenso_percentuale AS
 WITH p AS (
         SELECT sp.slot_id, sp.user_id, sp.percentuale
           FROM slot_piano_staff sp
          WHERE sp.compenso_tipo = 'percentuale'::text
        ), d AS (
         SELECT DISTINCT i.slot_id, i.data, p.user_id AS titolare_id, p.percentuale
           FROM impegni_staff i
             JOIN p ON p.slot_id = i.slot_id
          WHERE i.tipo = 'lezione'::text AND i.stato <> 'ritirato'::text
        )
 SELECT d.titolare_id AS user_id,
    COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(pe.nome, ''::text) || ' '::text) || COALESCE(pe.cognome, ''::text)), ''::text), '—'::text) AS persona,
    date_trunc('month'::text, d.data::timestamp with time zone)::date AS mese,
    d.data,
    d.slot_id,
    c.tipo_corso,
    c.fascia,
    c.ora_inizio,
    c.ora_fine,
    d.percentuale,
    t.stato AS stato_titolare,
    s.user_id AS sostituto_user_id,
    COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(pe2.nome, ''::text) || ' '::text) || COALESCE(pe2.cognome, ''::text)), ''::text), NULL::text) AS sostituto,
    s.stato AS stato_sostituto,
        CASE
            WHEN t.stato = 'presente'::text THEN 'fatta'::text
            WHEN s.stato = 'presente'::text THEN 'sostituita'::text
            WHEN COALESCE(t.stato, s.stato) = 'previsto'::text AND d.data < CURRENT_DATE THEN 'da_confermare'::text
            WHEN COALESCE(t.stato, s.stato) = 'previsto'::text THEN 'prevista'::text
            ELSE 'non_fatta'::text
        END AS esito,
        CASE
            WHEN s.stato = 'presente'::text THEN
            CASE
                WHEN s.compenso_tipo = 'percentuale'::text THEN 0::numeric
                WHEN s.compenso_tipo = 'lezione'::text THEN COALESCE(ts.euro_lezione, 15::numeric)
                ELSE round(EXTRACT(epoch FROM s.ora_fine - s.ora_inizio) / 3600.0 * COALESCE(ts.euro_ora, 5::numeric), 2)
            END
            ELSE 0::numeric
        END AS euro_sostituto,
        CASE
            WHEN t.stato IS DISTINCT FROM 'presente'::text AND s.stato = 'presente'::text THEN
            CASE
                WHEN s.compenso_tipo = 'percentuale'::text THEN 0::numeric
                WHEN s.compenso_tipo = 'lezione'::text THEN COALESCE(ts.euro_lezione, 15::numeric)
                ELSE round(EXTRACT(epoch FROM s.ora_fine - s.ora_inizio) / 3600.0 * COALESCE(ts.euro_ora, 5::numeric), 2)
            END
            ELSE 0::numeric
        END AS euro_da_scalare
   FROM d
     JOIN corsi_attivi_settimanali c ON c.id = d.slot_id
     LEFT JOIN impegni_staff t ON t.slot_id = d.slot_id AND t.data = d.data AND t.user_id = d.titolare_id AND t.tipo = 'lezione'::text AND t.stato <> 'ritirato'::text
     LEFT JOIN impegni_staff s ON s.slot_id = d.slot_id AND s.data = d.data AND s.user_id <> d.titolare_id AND s.tipo = 'lezione'::text AND s.ruolo = 'conduce'::text AND (s.stato = ANY (ARRAY['previsto'::text, 'presente'::text]))
     LEFT JOIN tariffe_staff ts ON ts.user_id = s.user_id
     LEFT JOIN profile_data pd ON pd.user_id = d.titolare_id
     LEFT JOIN persone pe ON pe.id = pd.persona_id
     LEFT JOIN profile_data pd2 ON pd2.user_id = s.user_id
     LEFT JOIN persone pe2 ON pe2.id = pd2.persona_id
  WHERE d.titolare_id = auth.uid() OR is_segreteria();
COMMENT ON VIEW public.v_compenso_percentuale IS
  'Lezioni dei titolari a percentuale (slot_piano_staff.compenso_tipo = percentuale): fatte, sostituite e quanto si scala dalla quota. Il conto del mese (incassi, quota, netto) è in v_compenso_percentuale_mese (consegna 29 ott 2026).';
REVOKE ALL ON public.v_compenso_percentuale FROM PUBLIC, anon;
GRANT SELECT ON public.v_compenso_percentuale TO authenticated, service_role;

-- 3f. compenso_percentuale_eccezioni: i casi decisi da Marco (30 ott 2026) in cui il conto a percentuale
--     NON usa il pagamento così com'è. Regola generale: si conta quello che è entrato davvero (sconti
--     normali dentro), diviso in parti uguali sui mesi dal → al del pagamento. Non tocca abbonamenti_pagamenti.
--     tipo 'periodo' = quel pagamento, per il conto, copre un altro periodo (importo uguale);
--     tipo 'allievo_mese' = per quella persona e quel corso non si usano i suoi pagamenti: vale euro_mese
--                            per ogni mese in cui è iscritta al corso (iscrizioni_minori).
CREATE TABLE public.compenso_percentuale_eccezioni (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo text NOT NULL CHECK (tipo IN ('periodo', 'allievo_mese')),
  pagamento_id uuid REFERENCES public.abbonamenti_pagamenti(id) ON DELETE CASCADE,
  dal date,
  al date,
  persona_id uuid REFERENCES public.persone(id) ON DELETE CASCADE,
  tipo_corso text,
  euro_mese numeric CHECK (euro_mese >= 0),
  motivo text NOT NULL,
  deciso_il date NOT NULL DEFAULT CURRENT_DATE,
  CONSTRAINT compenso_percentuale_eccezioni_forma CHECK (
    (tipo = 'periodo' AND pagamento_id IS NOT NULL AND dal IS NOT NULL AND al IS NOT NULL AND al >= dal
       AND persona_id IS NULL AND tipo_corso IS NULL AND euro_mese IS NULL)
    OR
    (tipo = 'allievo_mese' AND persona_id IS NOT NULL AND tipo_corso IS NOT NULL AND euro_mese IS NOT NULL
       AND pagamento_id IS NULL AND dal IS NULL AND al IS NULL))
);
CREATE UNIQUE INDEX compenso_percentuale_eccezioni_pagamento_uq ON public.compenso_percentuale_eccezioni (pagamento_id) WHERE tipo = 'periodo';
CREATE UNIQUE INDEX compenso_percentuale_eccezioni_allievo_uq ON public.compenso_percentuale_eccezioni (persona_id, tipo_corso) WHERE tipo = 'allievo_mese';
COMMENT ON TABLE public.compenso_percentuale_eccezioni IS
  'Eccezioni decise da Marco al conto dei titolari a percentuale (v_compenso_percentuale_mese). periodo: il pagamento copre per il conto un altro periodo. allievo_mese: per quella persona e quel corso euro_mese per ogni mese di iscrizione, al posto dei suoi pagamenti. Solo per decisione di Marco.';
ALTER TABLE public.compenso_percentuale_eccezioni ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.compenso_percentuale_eccezioni FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.compenso_percentuale_eccezioni TO service_role;

INSERT INTO public.compenso_percentuale_eccezioni (tipo, pagamento_id, dal, al, persona_id, tipo_corso, euro_mese, motivo, deciso_il) VALUES
  -- Davide Costantini paga 90 € AL MESE (non è un quadrimestrale): il suo unico pagamento registrato,
  -- 90 € importato dal foglio il 7/10 con periodo set–dic, vale UN mese. Messo su settembre 2026, il primo
  -- mese del periodo segnato (DA CONFERMARE da Marco: se era ottobre, cambiare dal/al qui sotto).
  -- I mesi che pagherà dopo entrano da soli, con i loro pagamenti.
  ('periodo', 'c44e043f-afd4-4e8c-9fda-55e0563cc068', '2026-09-01', '2026-09-30', NULL, NULL, NULL,
   'Davide Costantini: paga 90 € al mese, non quadrimestrale. Il pagamento da 90 € importato il 7/10 copre un mese solo (settembre 2026).', '2026-10-30'),
  -- Tommaso Pescetelli, unica eccezione: per il conto di Mello è un allievo normale, 90 € per ogni mese
  -- in cui è iscritto all'Expert, senza il suo sconto.
  ('allievo_mese', NULL, NULL, NULL, '7f86ffe2-7272-4c5a-86f6-551713655c48', 'expert', 90,
   'Tommaso Pescetelli: per il conto di Mello vale 90 € per ogni mese di iscrizione all''Expert, senza il suo sconto (unica eccezione).', '2026-10-30');

-- 3g. v_compenso_percentuale_mese: il conto del mese, una riga per titolare, corso e mese.
--     Incassi = abbonamenti_pagamenti dello stesso tipo del corso (tipo_abbonamento = tipo_corso),
--     cioè quello che è entrato davvero (sconti normali compresi), ogni pagamento diviso in parti uguali
--     sui mesi che copre, da dal ad al (decisione Marco 30 ott). Un pagamento non ancora fatto non c'è
--     in abbonamenti_pagamenti, quindi non entra finché non viene registrato.
--     I centesimi che avanzano dalla divisione vanno sul primo mese, così la somma torna al pagamento.
--     Eccezioni da compenso_percentuale_eccezioni: 'periodo' cambia dal/al del pagamento; 'allievo_mese'
--     toglie i pagamenti di quella persona per quel corso e mette euro_mese per ogni mese di iscrizione
--     (iscrizioni_minori dello stesso tipo, data_inizio → data_fine).
--     Iscrizioni da 40 €: in abbonamenti_pagamenti c'è solo la quota del corso (l'iscrizione annuale
--     si segna a parte, in pagamenti_manuali voce 'iscrizione'), quindi qui non c'è niente da togliere.
--     Mesi prima di slot_piano_staff.percentuale_dal: fuori dal conto (settembre 2026 saldato a mano).
--     netto = quota − da_scalare (pagato ai sostituti). Se va sotto 0 la vista lo mostra negativo:
--     non si registra niente, il portale lo mostra in rosso a Marco.
CREATE VIEW public.v_compenso_percentuale_mese AS
 WITH p AS (
         SELECT sp.slot_id, sp.user_id, sp.percentuale, sp.percentuale_dal, c.tipo_corso, c.fascia
           FROM slot_piano_staff sp
             JOIN corsi_attivi_settimanali c ON c.id = sp.slot_id
          WHERE sp.compenso_tipo = 'percentuale'::text
        ), r AS (
         SELECT ap.id, ap.tipo_abbonamento, ap.persona_id, ap.importo_eur,
            m.mese::date AS mese,
            count(*) OVER (PARTITION BY ap.id) AS n_mesi,
            row_number() OVER (PARTITION BY ap.id ORDER BY m.mese) AS k
           FROM abbonamenti_pagamenti ap
             LEFT JOIN compenso_percentuale_eccezioni ep ON ep.tipo = 'periodo'::text AND ep.pagamento_id = ap.id
             CROSS JOIN LATERAL generate_series(date_trunc('month'::text, COALESCE(ep.dal, ap.dal)::timestamp without time zone), date_trunc('month'::text, COALESCE(ep.al, ap.al)::timestamp without time zone), '1 mon'::interval) m(mese)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM compenso_percentuale_eccezioni ea
                  WHERE ea.tipo = 'allievo_mese'::text AND ea.persona_id = ap.persona_id AND ea.tipo_corso = ap.tipo_abbonamento))
        ), q AS (
         SELECT r.tipo_abbonamento, r.persona_id, r.mese,
                CASE
                    WHEN r.k = 1 THEN r.importo_eur - round(r.importo_eur / r.n_mesi::numeric, 2) * (r.n_mesi - 1)::numeric
                    ELSE round(r.importo_eur / r.n_mesi::numeric, 2)
                END AS quota_mese
           FROM r
        UNION ALL
         SELECT DISTINCT ea.tipo_corso, ea.persona_id, m.mese::date AS mese, ea.euro_mese
           FROM compenso_percentuale_eccezioni ea
             JOIN iscrizioni_minori im ON im.persona_id = ea.persona_id AND im.tipo_abbonamento = ea.tipo_corso
             CROSS JOIN LATERAL generate_series(date_trunc('month'::text, im.data_inizio::timestamp without time zone), date_trunc('month'::text, im.data_fine::timestamp without time zone), '1 mon'::interval) m(mese)
          WHERE ea.tipo = 'allievo_mese'::text
        ), inc AS (
         SELECT p.slot_id, p.user_id, q.mese, count(DISTINCT q.persona_id) AS allievi_paganti, sum(q.quota_mese) AS incassi
           FROM p
             JOIN q ON q.tipo_abbonamento = p.tipo_corso
          GROUP BY p.slot_id, p.user_id, q.mese
        ), lez AS (
         SELECT v.slot_id, v.user_id, v.mese,
            count(*) FILTER (WHERE v.esito = 'fatta'::text) AS lezioni_fatte,
            count(*) FILTER (WHERE v.esito = 'sostituita'::text) AS lezioni_sostituite,
            count(*) FILTER (WHERE v.esito = 'da_confermare'::text) AS lezioni_da_confermare,
            sum(v.euro_da_scalare) AS da_scalare
           FROM v_compenso_percentuale v
          GROUP BY v.slot_id, v.user_id, v.mese
        ), mesi AS (
         SELECT inc.slot_id, inc.user_id, inc.mese FROM inc
        UNION
         SELECT lez.slot_id, lez.user_id, lez.mese FROM lez
        )
 SELECT m.user_id,
    m.mese,
    m.slot_id,
    p.tipo_corso,
    p.fascia,
    p.percentuale,
    COALESCE(inc.allievi_paganti, 0::bigint) AS allievi_paganti,
    COALESCE(inc.incassi, 0::numeric) AS incassi,
    round(COALESCE(inc.incassi, 0::numeric) * p.percentuale / 100::numeric, 2) AS quota,
    COALESCE(lez.lezioni_fatte, 0::bigint) AS lezioni_fatte,
    COALESCE(lez.lezioni_sostituite, 0::bigint) AS lezioni_sostituite,
    COALESCE(lez.lezioni_da_confermare, 0::bigint) AS lezioni_da_confermare,
    COALESCE(lez.da_scalare, 0::numeric) AS da_scalare,
    round(COALESCE(inc.incassi, 0::numeric) * p.percentuale / 100::numeric, 2) - COALESCE(lez.da_scalare, 0::numeric) AS netto,
    COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(pe.nome, ''::text) || ' '::text) || COALESCE(pe.cognome, ''::text)), ''::text), '—'::text) AS persona
   FROM mesi m
     JOIN p ON p.slot_id = m.slot_id AND p.user_id = m.user_id
     LEFT JOIN inc ON inc.slot_id = m.slot_id AND inc.user_id = m.user_id AND inc.mese = m.mese
     LEFT JOIN lez ON lez.slot_id = m.slot_id AND lez.user_id = m.user_id AND lez.mese = m.mese
     LEFT JOIN profile_data pd ON pd.user_id = m.user_id
     LEFT JOIN persone pe ON pe.id = pd.persona_id
  WHERE m.mese >= COALESCE(date_trunc('month'::text, p.percentuale_dal::timestamp without time zone)::date, '-infinity'::date)
    AND (m.user_id = auth.uid() OR is_segreteria());
COMMENT ON VIEW public.v_compenso_percentuale_mese IS
  'Conto del mese dei titolari a percentuale: incassi reali del corso (ogni pagamento diviso in parti uguali sui mesi dal→al; eccezioni in compenso_percentuale_eccezioni), quota, quanto pagato ai sostituti, netto. Solo dai mesi da percentuale_dal in poi. Netto negativo = solo da mostrare, non si registra (decisioni Marco 30 ott 2026).';
REVOKE ALL ON public.v_compenso_percentuale_mese FROM PUBLIC, anon;
GRANT SELECT ON public.v_compenso_percentuale_mese TO authenticated, service_role;

-- ───────────────────────────── CONTROLLI DOPO ─────────────────────────────
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '1. firma allineamento_decidi (deve finire con p_slot_ids uuid[])', string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
 WHERE s.nspname = 'public' AND p.proname = 'allineamento_decidi';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '2. cambia_giorni_abbonamento blocca il cambio di numero di giorni (deve essere false)', (prosrc LIKE '%cambia il prezzo%')::text
  FROM pg_proc WHERE oid = 'public.cambia_giorni_abbonamento(uuid,uuid[],text)'::regprocedure;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3a. lezioni di Mellozzini su Expert/Giovani NON a percentuale (dopo: 0)', count(*)::text
  FROM public.impegni_staff WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND tipo = 'lezione' AND compenso_tipo <> 'percentuale';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3b. lezioni di Mellozzini su Expert/Giovani pagate a lezione, euro > 0 (dopo: 0)', count(*)::text
  FROM public.v_compenso_lezioni WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND euro > 0;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3c. lezioni di Mellozzini su Expert/Giovani da confermare (restano uguali: servono per le sostituzioni)', count(*)::text
  FROM public.v_compenso_lezioni WHERE user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c') AND da_confermare;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3d. quota nel piano (deve essere 30 dal 2026-10-01 su expert e giovani)', string_agg(c.tipo_corso || ' ' || sp.compenso_tipo || ' ' || sp.percentuale || ' dal ' || sp.percentuale_dal, ' | ' ORDER BY c.tipo_corso)
  FROM public.slot_piano_staff sp JOIN public.corsi_attivi_settimanali c ON c.id = sp.slot_id
 WHERE sp.user_id = 'e4841ae2-aeef-4007-839d-7837d197195b' AND sp.slot_id IN ('9c2150c8-212a-41fb-9e00-bffc953adf2e','895b3610-a95c-4167-8eca-ed7cd704e92c');
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3e. v_compenso_percentuale: lezioni lette (Marco come utente)', count(*)::text FROM public.v_compenso_percentuale;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3f. eccezioni al conto (Costantini: periodo 2026-09-01→2026-09-30 · Pescetelli: allievo_mese expert 90)',
       string_agg(tipo || ' ' || coalesce(dal || '→' || al, tipo_corso || ' ' || euro_mese), ' · ' ORDER BY tipo DESC)
  FROM public.compenso_percentuale_eccezioni;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '3g. conto del mese ' || tipo_corso || ' ' || to_char(mese, 'YYYY-MM'),
       'incassi ' || incassi || ' · quota ' || quota || ' · scalato ' || da_scalare || ' · netto ' || netto
  FROM public.v_compenso_percentuale_mese ORDER BY tipo_corso, mese;
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '4. Prime Lezioni nella stessa ora di un corso dello stesso istruttore pagate, euro > 0 (dopo: 0)', count(*)::text
  FROM public.v_compenso_lezioni v
 WHERE v.tipo_corso LIKE 'prima_lezione%' AND v.euro > 0
   AND EXISTS (SELECT 1 FROM public.impegni_staff o JOIN public.corsi_attivi_settimanali oc ON oc.id = o.slot_id
                WHERE o.user_id = v.user_id AND o.data = v.data AND o.id <> v.impegno_id AND o.tipo = 'lezione'
                  AND o.stato IN ('previsto','presente') AND oc.tipo_corso NOT LIKE 'prima_lezione%'
                  AND o.ora_inizio < v.ora_fine AND o.ora_fine > v.ora_inizio);

COMMIT;

SELECT momento, controllo, valore FROM _controllo_291026 ORDER BY controllo, n;
