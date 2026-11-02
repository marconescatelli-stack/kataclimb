-- ═══ COME ARRIVARE AL CANCELLO — giorno stesso della Prima Lezione (consegna 30 ott 2026, Task 2) ═══
-- NON APPLICARE PRIMA DEL DEPLOY di kataclimb-notifiche con la gestione di 'come_arrivare.prima_lezione':
-- il Worker live (v2.5) non conosce questo tipo di evento.
--
-- Cosa fa: cron_genera_eventi_mattutini() (lanciata ogni notte alle 00:00 UTC) ha una sezione in piu', la 7:
-- per ogni Prima Lezione prenotata OGGI crea l'evento 'come_arrivare.prima_lezione' (mail Brevo #17 + push),
-- schedulato alle 09:00 Europe/Rome dello stesso giorno. Stesse righe e stessi filtri della sezione 4
-- (promemoria.prima_lezione, che resta com'e'), ma su data_lezione = oggi; destinatario da _referente_notifica
-- (il genitore per i minori). Payload: nome, nome_allievo, via_genitore, data, ora, nome_lezione e, se lo slot ha
-- l'istruttore, istruttore = istruttori.nome per intero (es. «Giammarco (Gimmy)»), come nelle mail di conferma.
-- dedup_key = 'come_arrivare.prima_lezione:<prenotazione_id>:<data>'.
-- Le sezioni 1–6 sono IDENTICHE alla definizione live del 30/10 (letta con pg_get_functiondef): regola primaria,
-- si aggiunge e non si sostituisce. Il risultato ha due chiavi in piu': come_arrivare_processati, come_arrivare_saltati.
-- Slot Prima Lezione attivi al 30/10: tutti dalle 17:00 in poi, quindi le 09:00 arrivano sempre prima della lezione.
-- La funzione la chiama il Worker a ogni giro (ogni ~10 minuti, visto dagli invii): una Prima Lezione prenotata in
-- giornata dopo le 09:00 riceve l'avviso al giro successivo; dopo l'ora di inizio della lezione non si crea piu'.
-- Brevo #17 va ATTIVATO prima di applicare questo file: con il template inattivo la mail fallisce e l'evento va in errore.

CREATE OR REPLACE FUNCTION public.cron_genera_eventi_mattutini()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  rec                record;
  v_ultima_count     int := 0;
  v_promemoria_count int := 0;
  v_advance_count    int := 0;
  v_memo_count       int := 0;
  v_prima_count      int := 0;
  v_prima_saltati    int := 0;
  v_prima_staff      int := 0;
  v_quest_count      int := 0;
  v_via_genitore     int := 0;
  v_oggi             date := CURRENT_DATE;
  v_e_ultima         boolean;
  v_nuovi_colpi      int;
  v_spegni           boolean;
  v_dest             record;
  v_arrivo_count     int := 0;
  v_arrivo_saltati   int := 0;
BEGIN
  -- 1) LEZIONI DI OGGI
  FOR rec IN
    SELECT DISTINCT pc.user_id, pd.corso_attivo AS corso, pd.persona_id
    FROM prenotazioni_corso pc
    JOIN profile_data pd ON pd.user_id = pc.user_id
    WHERE pc.stato = 'prenotato'
      AND pc.data_lezione = v_oggi
      AND pd.corso_attivo IS NOT NULL
  LOOP
    v_e_ultima := (
      _get_lezioni_residue(rec.user_id, rec.corso) <= 0
      AND NOT EXISTS (
        SELECT 1 FROM prenotazioni_corso
        WHERE user_id = rec.user_id
          AND stato = 'prenotato'
          AND data_lezione > v_oggi
      )
      -- FIX 15 ott 2026: fine Mezza1 non e' l'ultima lezione dell'Open
      AND NOT EXISTS (
        SELECT 1 FROM iscrizioni_corso ic
        WHERE ic.user_id = rec.user_id AND ic.tipo_corso = 'open'
          AND ic.status = 'attiva' AND ic.lezioni_totali < 7
          AND rec.corso = 'open'
      )
    );

    IF v_e_ultima THEN
      PERFORM registra_evento_notifica(
        'ultima_lezione.allievo', rec.user_id, 'both',
        jsonb_build_object('corso', rec.corso, 'data', v_oggi),
        now(), 'ultima_lezione.allievo:' || rec.user_id || ':' || v_oggi
      );
      PERFORM registra_evento_notifica(
        'ultima_lezione.staff', rec.user_id, 'email',
        jsonb_build_object('corso', rec.corso, 'data', v_oggi),
        now(), 'ultima_lezione.staff:' || rec.user_id || ':' || v_oggi
      );
      v_ultima_count := v_ultima_count + 1;
    ELSE
      PERFORM registra_evento_notifica(
        'promemoria.lezione', rec.user_id, 'both',
        jsonb_build_object('corso', rec.corso, 'data', v_oggi),
        now(), 'promemoria.lezione:' || rec.user_id || ':' || v_oggi
      );
      v_promemoria_count := v_promemoria_count + 1;
    END IF;
  END LOOP;

  -- 2) OFFERTA ADVANCE
  FOR rec IN
    SELECT pd.user_id, pd.persona_id
    FROM lead_data ld
    JOIN profile_data pd ON pd.persona_id = ld.persona_id
    WHERE ld.funnel_stage = 'concluso_open'
  LOOP
    PERFORM registra_evento_notifica(
      'offerta.advance', rec.user_id, 'email',
      jsonb_build_object('corso_concluso', 'open', 'corso_proposto', 'advance'),
      now(), 'offerta.advance:' || rec.persona_id
    );
    v_advance_count := v_advance_count + 1;
  END LOOP;

  -- 3) MEMO "PRENOTA"
  FOR rec IN
    SELECT pd.user_id,
           pd.corso_attivo AS corso,
           COALESCE(om.colpi_inviati, 0) AS colpi
    FROM profile_data pd
    LEFT JOIN onboarding_memo om
           ON om.user_id = pd.user_id
          AND om.corso   = pd.corso_attivo
    WHERE pd.corso_attivo IS NOT NULL
      AND COALESCE(pd.prenota_autonoma, false) = false
      AND COALESCE(om.spento, false) = false
      AND COALESCE(om.colpi_inviati, 0) < 6
      AND NOT EXISTS (
        SELECT 1 FROM prenotazioni_corso pc
        WHERE pc.user_id = pd.user_id
          AND pc.tipo_corso = pd.corso_attivo
          AND pc.stato = 'prenotato'
      )
      AND (
        om.ultimo_colpo_at IS NULL
        OR om.ultimo_colpo_at <= (now() - interval '2 days')
      )
  LOOP
    v_nuovi_colpi := rec.colpi + 1;
    v_spegni      := (v_nuovi_colpi >= 6);

    PERFORM registra_evento_notifica(
      'promemoria.prenota', rec.user_id, 'both',
      jsonb_build_object('corso', rec.corso, 'colpo', v_nuovi_colpi),
      now(),
      'promemoria.prenota:' || rec.user_id || ':' || rec.corso || ':' || v_nuovi_colpi
    );

    INSERT INTO onboarding_memo
        (user_id, corso, colpi_inviati, ultimo_colpo_at, spento, spento_motivo, spento_at, updated_at)
      VALUES
        (rec.user_id, rec.corso, v_nuovi_colpi, now(),
         v_spegni, CASE WHEN v_spegni THEN 'max_colpi' ELSE NULL END,
         CASE WHEN v_spegni THEN now() ELSE NULL END, now())
    ON CONFLICT (user_id, corso) DO UPDATE
      SET colpi_inviati   = v_nuovi_colpi,
          ultimo_colpo_at = now(),
          spento          = v_spegni,
          spento_motivo   = CASE WHEN v_spegni THEN 'max_colpi' ELSE onboarding_memo.spento_motivo END,
          spento_at       = CASE WHEN v_spegni THEN now() ELSE onboarding_memo.spento_at END,
          updated_at      = now();

    v_memo_count := v_memo_count + 1;
  END LOOP;

  -- 4) PROMEMORIA GIORNO-PRIMA PRIMA LEZIONE (22 lug · 5 set: minori → genitore)
  FOR rec IN
    SELECT ppl.id            AS prenotazione_id,
           ld.persona_id,
           ppl.data_lezione,
           to_char(cas.ora_inizio, 'HH24:MI') AS ora,
           cas.fascia,
           p.nome            AS nome_persona
    FROM prenotazioni_prima_lezione ppl
    JOIN lead_data ld  ON ld.id = ppl.lead_id
    JOIN persone   p   ON p.id  = ld.persona_id
    JOIN corsi_attivi_settimanali cas ON cas.id = ppl.slot_id
    WHERE ppl.stato = 'prenotato'
      AND ppl.data_lezione = v_oggi + 1
  LOOP
    SELECT * INTO v_dest FROM _referente_notifica(rec.persona_id);
    IF v_dest.user_id IS NULL THEN
      v_prima_saltati := v_prima_saltati + 1;
      CONTINUE;
    END IF;
    IF v_dest.via_genitore THEN v_via_genitore := v_via_genitore + 1; END IF;

    PERFORM registra_evento_notifica(
      'promemoria.prima_lezione', v_dest.user_id, 'both',
      jsonb_build_object(
        'nome',         CASE WHEN v_dest.via_genitore THEN v_dest.nome_genitore ELSE rec.nome_persona END,
        'nome_allievo', rec.nome_persona,
        'via_genitore', v_dest.via_genitore,
        'data',         rec.data_lezione,
        'ora',          rec.ora,
        'nome_lezione', CASE rec.fascia
                          WHEN 'bambini' THEN 'Prima Lezione Bambini (6–11)'
                          WHEN 'ragazzi' THEN 'Prima Lezione Ragazzi (12–17)'
                          ELSE 'Prima Lezione Adulti'
                        END
      ),
      now(),
      'promemoria.prima_lezione:' || rec.prenotazione_id || ':' || rec.data_lezione
    );
    v_prima_count := v_prima_count + 1;
  END LOOP;

  -- 5) PRIMA LEZIONE OGGI -> AVVISO STAFF (22 lug · 5 set: telefono del genitore se minore senza recapito)
  FOR rec IN
    SELECT ppl.id            AS prenotazione_id,
           ld.persona_id,
           ppl.data_lezione,
           to_char(cas.ora_inizio, 'HH24:MI') AS ora,
           cas.fascia,
           p.nome            AS nome_persona,
           p.cognome         AS cognome_persona,
           p.telefono        AS telefono
    FROM prenotazioni_prima_lezione ppl
    JOIN lead_data ld  ON ld.id = ppl.lead_id
    JOIN persone   p   ON p.id  = ld.persona_id
    JOIN corsi_attivi_settimanali cas ON cas.id = ppl.slot_id
    WHERE ppl.stato = 'prenotato'
      AND ppl.data_lezione = v_oggi
  LOOP
    SELECT * INTO v_dest FROM _referente_notifica(rec.persona_id);

    PERFORM registra_evento_notifica(
      'prima_lezione.oggi.staff', NULL, 'push',
      jsonb_build_object(
        'nome',         rec.nome_persona,
        'cognome',      rec.cognome_persona,
        'telefono',     COALESCE(rec.telefono, v_dest.telefono_genitore),
        'genitore',     CASE WHEN rec.telefono IS NULL AND v_dest.telefono_genitore IS NOT NULL THEN v_dest.nome_genitore END,
        'data',         rec.data_lezione,
        'ora',          rec.ora,
        'nome_lezione', CASE rec.fascia
                          WHEN 'bambini' THEN 'Prima Lezione Bambini (6–11)'
                          WHEN 'ragazzi' THEN 'Prima Lezione Ragazzi (12–17)'
                          ELSE 'Prima Lezione Adulti'
                        END
      ),
      now(),
      'prima_lezione.oggi.staff:' || rec.prenotazione_id || ':' || rec.data_lezione
    );
    v_prima_staff := v_prima_staff + 1;
  END LOOP;

  -- 6) QUESTIONARIO DI VALORIZZAZIONE — giorno dopo la Prima con presenza (22 lug · 5 set: minori → genitore)
  FOR rec IN
    SELECT ppl.id            AS prenotazione_id,
           ld.persona_id,
           p.nome            AS nome_persona,
           cas.fascia
    FROM prenotazioni_prima_lezione ppl
    JOIN lead_data ld  ON ld.id = ppl.lead_id
    JOIN persone   p   ON p.id  = ld.persona_id
    JOIN corsi_attivi_settimanali cas ON cas.id = ppl.slot_id
    WHERE ppl.presente = true
      AND ppl.data_lezione = v_oggi - 1
      AND NOT EXISTS (SELECT 1 FROM questionari_valorizzazione qv
                      WHERE qv.prenotazione_id = ppl.id)
  LOOP
    SELECT * INTO v_dest FROM _referente_notifica(rec.persona_id);
    IF v_dest.user_id IS NULL THEN
      CONTINUE;
    END IF;
    IF v_dest.via_genitore THEN v_via_genitore := v_via_genitore + 1; END IF;

    PERFORM registra_evento_notifica(
      'questionario.prima_lezione', v_dest.user_id, 'both',
      jsonb_build_object(
        'nome',            CASE WHEN v_dest.via_genitore THEN v_dest.nome_genitore ELSE rec.nome_persona END,
        'nome_allievo',    rec.nome_persona,
        'via_genitore',    v_dest.via_genitore,
        'prenotazione_id', rec.prenotazione_id,
        'nome_lezione',    CASE rec.fascia
                             WHEN 'bambini' THEN 'Prima Lezione Bambini (6–11)'
                             WHEN 'ragazzi' THEN 'Prima Lezione Ragazzi (12–17)'
                             ELSE 'Prima Lezione Adulti'
                           END
      ),
      now(),
      'questionario.prima_lezione:' || rec.prenotazione_id
    );
    v_quest_count := v_quest_count + 1;
  END LOOP;

  -- 7) COME ARRIVARE AL CANCELLO — giorno stesso della Prima Lezione, alle 09:00 Europe/Rome (30 ott 2026: minori → genitore)
  --    Stesse righe e filtri della 4 ma su oggi; + istruttore dello slot (istruttori.nome per intero), se c'e'.
  FOR rec IN
    SELECT ppl.id            AS prenotazione_id,
           ld.persona_id,
           ppl.data_lezione,
           to_char(cas.ora_inizio, 'HH24:MI') AS ora,
           cas.fascia,
           p.nome            AS nome_persona,
           ist.nome          AS istruttore
    FROM prenotazioni_prima_lezione ppl
    JOIN lead_data ld  ON ld.id = ppl.lead_id
    JOIN persone   p   ON p.id  = ld.persona_id
    JOIN corsi_attivi_settimanali cas ON cas.id = ppl.slot_id
    LEFT JOIN istruttori ist ON ist.id = cas.istruttore_id
    WHERE ppl.stato = 'prenotato'
      AND ppl.data_lezione = v_oggi
      -- la funzione gira a ogni giro del Worker (ogni ~10 minuti): chi prenota in giornata riceve l'avviso subito,
      -- ma mai dopo l'inizio della lezione
      AND now() < (v_oggi + cas.ora_inizio) AT TIME ZONE 'Europe/Rome'
  LOOP
    SELECT * INTO v_dest FROM _referente_notifica(rec.persona_id);
    IF v_dest.user_id IS NULL THEN
      v_arrivo_saltati := v_arrivo_saltati + 1;
      CONTINUE;
    END IF;

    PERFORM registra_evento_notifica(
      'come_arrivare.prima_lezione', v_dest.user_id, 'both',
      jsonb_build_object(
        'nome',         CASE WHEN v_dest.via_genitore THEN v_dest.nome_genitore ELSE rec.nome_persona END,
        'nome_allievo', rec.nome_persona,
        'via_genitore', v_dest.via_genitore,
        'data',         rec.data_lezione,
        'ora',          rec.ora,
        'nome_lezione', CASE rec.fascia
                          WHEN 'bambini' THEN 'Prima Lezione Bambini (6–11)'
                          WHEN 'ragazzi' THEN 'Prima Lezione Ragazzi (12–17)'
                          ELSE 'Prima Lezione Adulti'
                        END
      ) || CASE WHEN nullif(trim(rec.istruttore),'') IS NOT NULL
                THEN jsonb_build_object('istruttore', trim(rec.istruttore)) ELSE '{}'::jsonb END,
      (v_oggi + time '09:00') AT TIME ZONE 'Europe/Rome',
      'come_arrivare.prima_lezione:' || rec.prenotazione_id || ':' || rec.data_lezione
    );
    v_arrivo_count := v_arrivo_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'eseguito_il', now(),
    'ultima_lezione_processate', v_ultima_count,
    'promemoria_processati',     v_promemoria_count,
    'offerta_advance_processate', v_advance_count,
    'memo_prenota_processati',   v_memo_count,
    'promemoria_prima_processati', v_prima_count,
    'promemoria_prima_saltati',    v_prima_saltati,
    'prima_oggi_staff_processati', v_prima_staff,
    'questionari_prima_processati', v_quest_count,
    'via_genitore',                 v_via_genitore,
    'come_arrivare_processati',     v_arrivo_count,
    'come_arrivare_saltati',        v_arrivo_saltati
  );
END;
$function$;
