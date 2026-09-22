-- ============================================================================
-- DEBITO-190 · Fase A · 01 — Lettura unica dei contatori di corso
-- Data: 2026-09-21 · Decisioni: Marco (Master v3.110 §2 + risposte al censimento)
--
-- SCOPO
--   Creare la sola fonte di verità per i numeri di un percorso. Da qui in poi
--   nessuna funzione deve più tenere un contatore salvato: ogni numero è un
--   COUNT su prenotazioni_corso, più lezioni_totali dell'iscrizione attiva.
--
--   Questo file NON scrive dati e NON tocca le colonne *_residue esistenti:
--   crea solo una view e una funzione di lettura. Rischio: nullo.
--
-- MAPPATURA DEGLI STATI (decisa da Marco — i 5 stati reali NON si normalizzano,
-- la mappatura vive solo qui dentro):
--   stato reale           significato            consuma?            budget spostamenti?
--   presente              fatta                  sì, 1 a 1           no
--   assente               ghostata (no-show)     ogni N, vedi sotto  no
--   cancellato_tardi      disdetta fuori tempo   sì, 1 a 1           no
--   cancellato_in_tempo   spostata in tempo      no                  sì
--   prenotato             in agenda (futura)     non ancora          no
--
-- LA REGOLA DEL NO-SHOW (Modello Open, confermata da Marco il 22 set)
--   Una ghostata da sola NON scala niente: ne servono N, dove N e' la soglia
--   letta da tipi_corso_config.noshow_soglia_penalita (oggi 2 su tutti e
--   quattro i corsi). Mai un 2 scritto a mano: se domani la soglia cambia,
--   cambia qui e basta.
--     1 ghostata  → 0 lezioni scalate      3 ghostate → 1 lezione scalata
--     2 ghostate  → 1 lezione scalata      4 ghostate → 2 lezioni scalate
--   E' una divisione intera: ghostate / soglia.
--   Nessun contatore da azzerare: il numero e' sempre ricavato dal COUNT.
--
-- PREREQUISITI
--   - Nessuno. Si applica su DB live senza fermare nulla.
--
-- SCELTE DA SAPERE, verificate sui dati del 21 set 2026
--   1) Le presenze si contano per (user_id, tipo_corso) SENZA filtro di data:
--      le iscrizioni retroattive hanno presenze precedenti a data_inizio_validita.
--      Conseguenza: se un utente ha due iscrizioni dello stesso tipo, le presenze
--      di entrambe finiscono sull'attiva. Oggi capita a UN solo utente
--      (intro_corda: una 'terminata' + una 'attiva') ed è proprio il caso Baldina
--      che la Fase D deve bonificare. Verificato: nessun altro caso.
--   2) spostamenti_usati NON è filtrato sulla finestra di validità. Delle 9 righe
--      'cancellato_in_tempo' a DB, 5 appartengono a tipi senza iscrizione attiva
--      (quindi fuori da questa view) e le altre 4 cadono tutte DENTRO la finestra:
--      oggi filtrare o non filtrare dà lo stesso numero. Se un giorno divergesse,
--      lo intercetta la query di controllo in fondo a questo file.
--   3) totali usa la divisione intera: lezioni_totali/2 su 8 dà 4, su 7 darebbe 3.
--      Oggi advance/intro_corda/evo_corda hanno pacchetti da 8, quindi non morde.
--   4b) La soglia del no-show viene da tipi_corso_config.noshow_soglia_penalita
--      e non da un 2 scritto a mano: se domani la penale cambia, cambia li'.
--   4) restano e prenotabili NON sono limitati a zero di proposito: devono poter
--      andare negativi, altrimenti la 02_audit_scarti non vedrebbe i dati storti.
--      Le guardie delle RPC (Fase B) useranno "prenotabili > 0".
--
-- VERIFICA DOPO L'APPLICAZIONE: le due query in fondo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- View: una riga per iscrizione ATTIVA dei 4 tipi che hanno prenotazioni.
-- Esclusi: gli altri tipi_corso (essence, fly, prima_lezione, lezioni_speciali),
-- che non hanno né potranno avere righe in prenotazioni_corso (CHECK sulla
-- tabella), e le iscrizioni con lezioni_totali = 0 (3 righe da bonificare in
-- Fase D: elencate da 02_audit_scarti.sql).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.contatori_corso;

CREATE VIEW public.contatori_corso
WITH (security_invoker = true) AS
WITH conteggi AS (
  SELECT
    p.user_id,
    p.tipo_corso,
    count(*) FILTER (WHERE p.stato = 'presente')            AS fatte,
    count(*) FILTER (WHERE p.stato = 'assente')             AS ghostate,
    count(*) FILTER (WHERE p.stato = 'cancellato_tardi')    AS disdette_tardi,
    count(*) FILTER (WHERE p.stato = 'cancellato_in_tempo') AS spostamenti_usati,
    count(*) FILTER (WHERE p.stato = 'prenotato'
                       AND p.data_lezione >= CURRENT_DATE)  AS in_agenda
  FROM public.prenotazioni_corso p
  GROUP BY p.user_id, p.tipo_corso
),
base AS (
  SELECT
    i.id                                AS iscrizione_id,
    i.user_id,
    pd.persona_id,
    i.tipo_corso,
    i.data_inizio_validita,
    i.data_fine_validita,
    i.disdette_no_show_max              AS spostamenti_max,
    -- Mese 1 non saldato: metà pacchetto, SOLO per i tre corsi a pacchetto e
    -- solo se l'importo concordato è noto. importo_concordato NULL = righe
    -- pregresse/backfill, trattate come saldate (decisione Marco).
    -- Open non si tocca mai: mezza1 ha già lezioni_totali = 4, intero 7.
    CASE
      WHEN i.tipo_corso IN ('advance','intro_corda','evo_corda')
       AND i.importo_concordato IS NOT NULL
       AND i.importo_pagato < i.importo_concordato
      THEN i.lezioni_totali / 2
      ELSE i.lezioni_totali
    END                                 AS totali,
    -- soglia della penale no-show, dal config del tipo corso. GREATEST(...,1)
    -- e' solo una cintura contro una divisione per zero se il config fosse 0.
    GREATEST(coalesce(tc.noshow_soglia_penalita, 2), 1) AS soglia_ghost,
    coalesce(c.fatte,             0)    AS fatte,
    coalesce(c.ghostate,          0)    AS ghostate,
    coalesce(c.disdette_tardi,    0)    AS disdette_tardi,
    coalesce(c.spostamenti_usati, 0)    AS spostamenti_usati,
    coalesce(c.in_agenda,         0)    AS in_agenda
  FROM public.iscrizioni_corso i
  LEFT JOIN public.profile_data pd ON pd.user_id = i.user_id
  LEFT JOIN public.tipi_corso_config tc ON tc.tipo_corso = i.tipo_corso
  LEFT JOIN conteggi c             ON c.user_id  = i.user_id
                                  AND c.tipo_corso = i.tipo_corso
  WHERE i.status = 'attiva'
    AND i.tipo_corso IN ('open','advance','intro_corda','evo_corda')
    AND i.lezioni_totali > 0
)
SELECT
  b.iscrizione_id,
  b.user_id,
  b.persona_id,
  b.tipo_corso,
  b.totali,
  b.fatte,
  b.ghostate,
  b.soglia_ghost,
  -- quante lezioni hanno davvero eroso le ghostate: divisione intera sulla soglia
  (b.ghostate / b.soglia_ghost)                                           AS ghostate_scalate,
  b.disdette_tardi,
  -- quello che ha davvero eroso il pacchetto
  (b.fatte + b.disdette_tardi + b.ghostate / b.soglia_ghost)              AS consumate,
  (b.totali - (b.fatte + b.disdette_tardi + b.ghostate / b.soglia_ghost)) AS restano,
  b.in_agenda,
  (b.totali - (b.fatte + b.disdette_tardi + b.ghostate / b.soglia_ghost)
            - b.in_agenda)                                                AS prenotabili,
  b.spostamenti_usati,
  b.spostamenti_max,
  (b.spostamenti_max - b.spostamenti_usati)                               AS spostamenti_residui,
  b.data_inizio_validita,
  b.data_fine_validita
FROM base b;

COMMENT ON VIEW public.contatori_corso IS
  'DEBITO-190: unica fonte dei contatori di percorso. Ogni numero e'' derivato da '
  'prenotazioni_corso + iscrizioni_corso.lezioni_totali. Nessuna funzione deve '
  'scrivere contatori: si legge da qui. Una riga per iscrizione attiva dei 4 tipi '
  'con prenotazioni. consumate = presente + cancellato_tardi + (assente / soglia), '
  'con la soglia letta da tipi_corso_config.noshow_soglia_penalita.';

-- ---------------------------------------------------------------------------
-- Funzione di lettura per la UI (Fase C). Stessa verità della view.
-- p_tipo_corso NULL = tutti i percorsi attivi dell'utente.
-- SECURITY INVOKER: la RLS della view vale anche qui.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_contatori(uuid, text);

CREATE FUNCTION public.get_contatori(p_user_id uuid, p_tipo_corso text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.tipo_corso), '[]'::jsonb)
  FROM public.contatori_corso c
  WHERE c.user_id = p_user_id
    AND (p_tipo_corso IS NULL OR c.tipo_corso = p_tipo_corso);
$fn$;

COMMENT ON FUNCTION public.get_contatori(uuid, text) IS
  'DEBITO-190: contatori derivati per la UI. Torna un array jsonb (vuoto se non '
  'ci sono iscrizioni attive). p_tipo_corso NULL = tutti i percorsi.';

GRANT SELECT ON public.contatori_corso TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contatori(uuid, text) TO authenticated;

-- ============================================================================
-- VERIFICA DOPO L'APPLICAZIONE (da lanciare a mano, sola lettura)
-- ============================================================================
-- V0 · La regola del no-show incide su qualcuno? (informativa)
--   SELECT tipo_corso, ghostate, soglia_ghost, ghostate_scalate
--   FROM public.contatori_corso WHERE ghostate > 0;
--   Il 22 set 2026: NESSUNA riga. L'unica ghostata a DB sta su un profilo senza
--   iscrizione Open attiva, quindi fuori dalla view. Formula esercitata a vuoto:
--   quando la prima ghostata arrivera' su un'iscrizione viva, si rivedra' qui.
--
-- V1 · La view si legge e i numeri quadrano fra loro:
--   SELECT tipo_corso, count(*) AS iscrizioni,
--          sum(CASE WHEN restano <> totali - consumate THEN 1 ELSE 0 END)        AS restano_incoerenti,
--          sum(CASE WHEN prenotabili <> restano - in_agenda THEN 1 ELSE 0 END)   AS prenotabili_incoerenti,
--          sum(CASE WHEN restano < 0 THEN 1 ELSE 0 END)                          AS restano_negativi,
--          sum(CASE WHEN persona_id IS NULL THEN 1 ELSE 0 END)                   AS senza_persona_id
--   FROM public.contatori_corso GROUP BY tipo_corso ORDER BY tipo_corso;
--   Atteso: le tre colonne *_incoerenti e senza_persona_id a 0.
--   restano_negativi puo' essere > 0: sono i dati storti che la 02 elenca.
--
-- V2 · La scelta 2 qui sopra regge ancora (spostamenti dentro la finestra)?
--   SELECT count(*) AS spostamenti_fuori_finestra
--   FROM public.prenotazioni_corso p
--   JOIN public.contatori_corso c ON c.user_id = p.user_id AND c.tipo_corso = p.tipo_corso
--   WHERE p.stato = 'cancellato_in_tempo'
--     AND c.data_inizio_validita IS NOT NULL AND c.data_fine_validita IS NOT NULL
--     AND p.data_lezione NOT BETWEEN c.data_inizio_validita AND c.data_fine_validita;
--   Atteso oggi: 0. Se diventa > 0, il conteggio spostamenti va scopato alla finestra.
--
-- V3 · get_contatori risponde (sostituire lo user_id con uno reale):
--   SELECT public.get_contatori('00000000-0000-0000-0000-000000000000'::uuid);
--   Atteso: '[]' per un utente inesistente, un array di oggetti per uno reale.
