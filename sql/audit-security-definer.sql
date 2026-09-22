-- ============================================================================
-- CANTIERE A PARTE — Censimento delle funzioni SECURITY DEFINER
-- Data: 2026-09-22 · Preparata su richiesta di Marco · NON APPLICATA, NON APPLICABILE
--
-- Questo file non e' di DEBITO-190 e non modifica NIENTE: sono due SELECT.
-- Sta fuori da sql/debito-190/ apposta.
--
-- PERCHE' ESISTE
--   Durante la Fase B sono emerse tre cose, tutte sulla stessa famiglia:
--     · staff_attiva_corso — bypass staff via un booleano passato dal chiamante,
--       con EXECUTE ad anon. Chiunque avesse la chiave pubblica del sito poteva
--       attivare un corso a pagamento a chiunque. Chiusa a mano il 22 set.
--     · riconosci_percorso_pregresso — nessuna guardia staff, EXECUTE ad anon.
--       Il controllo esisteva solo nell'interfaccia (portale.html mostrava il
--       bottone con isStaff()), che non e' un controllo. Chiusa a mano il 22 set.
--     · get_cruscotto_percorsi — guardia che confronta staff_role con quattro
--       valori che non esistono nel CHECK: in pratica respinge segreteria e
--       creator. Ancora aperta.
--   Tre su tre trovate per caso, guardando altro. Questa query serve a smettere
--   di trovarle per caso.
--
-- COME SI LEGGE
--   Una funzione SECURITY DEFINER gira coi permessi di chi l'ha creata
--   (di solito postgres), non di chi la chiama. Se in piu' ha EXECUTE ad anon,
--   chiunque conosca la chiave pubblica — che sta in chiaro in ogni pagina —
--   puo' eseguirla. L'unica cosa che la protegge e' la guardia che ha dentro.
--   Quindi: SECURITY DEFINER + anon + nessuna guardia = porta aperta.
-- ============================================================================


-- ─── 1 · Tutte le SECURITY DEFINER, ordinate per quanto sono esposte ────────
SELECT
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS funzione,
  pg_get_userbyid(p.proowner) AS proprietario,
  CASE
    WHEN p.proacl IS NULL                                    THEN 'PUBLIC (ACL non impostata)'
    WHEN array_to_string(p.proacl,' ') LIKE '%anon=X%'        THEN 'anon + authenticated'
    WHEN array_to_string(p.proacl,' ') LIKE '%authenticated=X%' THEN 'authenticated'
    WHEN array_to_string(p.proacl,' ') LIKE '%service_role=X%'  THEN 'solo service_role'
    ELSE 'ristretta'
  END AS chi_puo_chiamarla,
  CASE
    WHEN pg_get_functiondef(p.oid) ~ 'is_staff\(\)|assert_staff\(\)'        THEN 'is_staff / assert_staff'
    WHEN pg_get_functiondef(p.oid) ~ 'staff_role'                           THEN 'controlla staff_role a mano'
    WHEN pg_get_functiondef(p.oid) ~ 'auth\.uid\(\)'                        THEN 'usa auth.uid(), da leggere'
    ELSE '>>> NESSUNA GUARDIA VISIBILE <<<'
  END AS guardia,
  -- il semaforo: rosso = SECURITY DEFINER, aperta ad anon, senza guardia
  CASE
    WHEN (p.proacl IS NULL OR array_to_string(p.proacl,' ') LIKE '%anon=X%')
     AND pg_get_functiondef(p.oid) !~ 'is_staff\(\)|assert_staff\(\)|staff_role|auth\.uid\(\)'
      THEN '1 · DA GUARDARE SUBITO'
    WHEN (p.proacl IS NULL OR array_to_string(p.proacl,' ') LIKE '%anon=X%')
      THEN '2 · aperta ad anon, ma una guardia ce l''ha'
    ELSE '3 · ristretta'
  END AS priorita
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef
ORDER BY priorita, funzione;


-- ─── 2 · Guardie che confrontano staff_role con valori che non esistono ─────
-- Il caso get_cruscotto_percorsi: una guardia che cita ruoli inesistenti non
-- protegge di piu', protegge di MENO — respinge chi dovrebbe passare, e chi
-- la legge crede che un controllo ci sia.
WITH ruoli_veri AS (
  SELECT unnest(ARRAY['staff_creator','staff_segreteria','staff_istruttore_tutor',
                      'staff_istruttore_sr','staff_istruttore_jr','staff_assistente',
                      'staff_monitor']) AS ruolo
), citati AS (
  SELECT p.proname,
         (regexp_matches(pg_get_functiondef(p.oid), '''([a-z_]+)''::text', 'g'))[1] AS valore
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND pg_get_functiondef(p.oid) ~ 'staff_role'
)
SELECT c.proname AS funzione,
       string_agg(DISTINCT c.valore, ', ' ORDER BY c.valore) AS valori_citati_che_non_esistono
FROM citati c
WHERE c.valore ~ '^(staff_|creator|admin|segreteria|istruttore)'
  AND c.valore NOT IN (SELECT ruolo FROM ruoli_veri)
GROUP BY c.proname
ORDER BY c.proname;
-- Atteso il 22 set: almeno get_cruscotto_percorsi, con
-- creator, admin, segreteria, istruttore_senior.
