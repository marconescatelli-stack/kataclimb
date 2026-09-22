-- ============================================================================
-- DEBITO-190 · Fase A · 02 — Audit: dove il contatore salvato mente
-- Data: 2026-09-21 · Decisioni: Marco
--
-- SCOPO
--   Validare la view contatori_corso PRIMA di andare in Fase B, mettendo a
--   confronto i numeri derivati con i contatori salvati in profile_data.
--   Nessuna scrittura: solo SELECT. Si puo' rilanciare quante volte si vuole.
--
-- IL METRO (deciso da Marco)
--   scarto = contatore salvato − prenotabili ora
--   dove "prenotabili ora" = restano − gia' in agenda.
--   Il contatore vecchio ha sempre scalato ALLA PRENOTAZIONE, non alla presenza:
--   confrontarlo con "restano" darebbe uno scarto finto pari alle prenotazioni
--   aperte. Con questo metro chi ha prenotazioni future resta a zero.
--
-- REGOLA DI OUTPUT
--   Nessun numero nudo. Ogni riga si legge in segreteria senza conoscere il DB.
--
-- PREREQUISITI
--   01_view_contatori_corso.sql applicato.
--
-- ATTESO il 21 set 2026 (verificato sui dati live prima della consegna)
--   Sezione 1: 18 righe esaminate, 16 a posto, 2 fuori posto —
--              Baldina Yulia Intro Corda +4 · Baldassarini Chiara Intro Corda −2.
--   Sezione 2: 11 righe di crediti orfani (Baldina Corso Advance 4 e Corso Open 3,
--              piu' altri 9 allievi: non era solo un caso isolato).
--   Sezione 3: 3 iscrizioni attive con 0 lezioni pagate (Fly e Lezioni Speciali).
--   Se la Sezione 1 mostra righe diverse da quelle due, FERMARSI e capire prima
--   di passare alla Fase B.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- SEZIONE 1 — Iscrizioni attive: il contatore salvato regge?
-- Una riga per iscrizione attiva dei 4 corsi con prenotazioni.
-- ---------------------------------------------------------------------------
WITH salvati AS (
  SELECT c.*,
         CASE c.tipo_corso
           WHEN 'open'        THEN pd.lezioni_residue
           WHEN 'advance'     THEN pd.advance_lezioni_residue
           WHEN 'intro_corda' THEN pd.intro_lezioni_residue
           WHEN 'evo_corda'   THEN pd.evo_lezioni_residue
         END AS salvato,
         coalesce(pr.cognome || ' ' || pr.nome, '(anagrafica mancante)') AS allievo,
         coalesce(tc.label, c.tipo_corso) AS corso
  FROM public.contatori_corso c
  JOIN public.profile_data pd      ON pd.user_id = c.user_id
  LEFT JOIN public.profiles pr     ON pr.user_id = c.user_id
  LEFT JOIN public.tipi_corso_config tc ON tc.tipo_corso = c.tipo_corso
)
SELECT
  CASE WHEN salvato = prenotabili THEN 'a posto' ELSE 'FUORI POSTO' END AS esito,
  allievo || ' · ' || corso
    || ' · ' || totali      || ' lezioni pagate'
    || ' · ' || fatte       || ' fatte'
    || ' · ' || ghostate    || ' ghostate'
    || ' · ' || disdette_tardi || ' disdette fuori tempo'
    || ' · ' || restano     || ' restano'
    || ' · ' || in_agenda   || ' gia in agenda'
    || ' · ' || prenotabili || ' prenotabili ora'
    || ' · contatore salvato dice ' || coalesce(salvato::text, 'niente')
    || CASE
         WHEN salvato IS NULL          THEN ' → nessun contatore salvato per questo corso'
         WHEN salvato = prenotabili    THEN ' → combacia'
         WHEN salvato > prenotabili    THEN ' → scarto +' || (salvato - prenotabili)
              || ' (il DB gli farebbe prenotare ' || (salvato - prenotabili) || ' lezioni in piu di quelle che ha pagato)'
         ELSE ' → scarto ' || (salvato - prenotabili)
              || ' (il DB gli fa prenotare ' || (prenotabili - salvato) || ' lezioni in meno di quelle che ha pagato)'
       END AS riga
FROM salvati
ORDER BY (salvato = prenotabili), abs(coalesce(salvato, 0) - prenotabili) DESC, allievo;


-- ---------------------------------------------------------------------------
-- SEZIONE 2 — Crediti salvati su corsi senza iscrizione attiva
-- Lezioni che il DB dice ancora disponibili su un percorso gia' chiuso, o mai
-- aperto. Non compaiono nella view (che mostra solo le iscrizioni attive) e
-- quindi sfuggono a qualunque controllo: vanno azzerati in Fase D.
-- ---------------------------------------------------------------------------
SELECT
  coalesce(pr.cognome || ' ' || pr.nome, '(anagrafica mancante)')
    || ' · ' || coalesce(tc.label, x.tipo_corso)
    || ' · ' || x.crediti || ' crediti salvati ma nessuna iscrizione attiva'
    || ' · ' || coalesce(
         (SELECT 'ultima iscrizione ' || i.status || ', ' || i.lezioni_completate || ' lezioni fatte su ' || i.lezioni_totali
          FROM public.iscrizioni_corso i
          WHERE i.user_id = pd.user_id AND i.tipo_corso = x.tipo_corso
          ORDER BY i.data_iscrizione DESC LIMIT 1),
         'nessuna iscrizione a questo corso, mai') AS riga
FROM public.profile_data pd
CROSS JOIN LATERAL (VALUES
    ('open',        pd.lezioni_residue),
    ('advance',     pd.advance_lezioni_residue),
    ('intro_corda', pd.intro_lezioni_residue),
    ('evo_corda',   pd.evo_lezioni_residue)
  ) AS x(tipo_corso, crediti)
LEFT JOIN public.profiles pr          ON pr.user_id = pd.user_id
LEFT JOIN public.tipi_corso_config tc ON tc.tipo_corso = x.tipo_corso
WHERE coalesce(x.crediti, 0) > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.iscrizioni_corso i2
    WHERE i2.user_id = pd.user_id AND i2.tipo_corso = x.tipo_corso AND i2.status = 'attiva')
ORDER BY x.crediti DESC, 1;


-- ---------------------------------------------------------------------------
-- SEZIONE 3 — Iscrizioni attive con 0 lezioni pagate
-- La view le esclude perche' "restano" sarebbe sempre 0 o negativo.
-- NOTA verificata il 21 set: tutte e 3 sono di tipi FUORI dai 4 con prenotazioni
-- (Fly, Lezioni Speciali), quindi oggi il filtro lezioni_totali > 0 non toglie
-- nulla che il filtro sui tipi non togliesse gia'. Restano da capire in Fase D:
-- un'iscrizione attiva con zero lezioni pagate o e' un errore o e' un percorso
-- che non si conta a lezioni.
-- ---------------------------------------------------------------------------
SELECT
  coalesce(pr.cognome || ' ' || pr.nome, '(anagrafica mancante)')
    || ' · ' || coalesce(tc.label, i.tipo_corso)
    || ' · iscrizione attiva con 0 lezioni pagate'
    || ' · ' || i.lezioni_completate || ' risultano fatte'
    || ' · iscritta il ' || i.data_iscrizione
    || CASE WHEN i.tipo_corso NOT IN ('open','advance','intro_corda','evo_corda')
            THEN ' · corso senza prenotazioni a calendario'
            ELSE ' · CORSO CON PRENOTAZIONI: da guardare per primo' END AS riga
FROM public.iscrizioni_corso i
LEFT JOIN public.profiles pr          ON pr.user_id = i.user_id
LEFT JOIN public.tipi_corso_config tc ON tc.tipo_corso = i.tipo_corso
WHERE i.status = 'attiva' AND i.lezioni_totali = 0
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- SEZIONE 4 (promemoria per la Fase D, non e' un difetto)
-- profile_data.lezioni_iniziali_residue non appartiene a nessuno dei 4 corsi e
-- non entra in questo audit, ma il 21 set risultava valorizzata su 19 righe:
-- va censita prima di toccarla nel file 05.
-- ---------------------------------------------------------------------------
SELECT 'lezioni_iniziali_residue valorizzata su ' || count(*) || ' profili'
       || ' — colonna non mappata ai 4 corsi, da censire prima del drop' AS riga
FROM public.profile_data
WHERE coalesce(lezioni_iniziali_residue, 0) > 0;
