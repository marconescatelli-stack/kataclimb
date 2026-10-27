-- ==========================================================================
-- DEBITO-191 · 06 · Le funzioni future
-- Preparato il 22 settembre 2026 · NON APPLICATO · decide Marco
--
-- I file 03, 04 e 05 chiudono le porte aperte oggi. Questo serve a non
-- riaprirle domani senza accorgersene.
--
-- IL PROBLEMA
--   In PostgreSQL una funzione appena creata concede EXECUTE a PUBLIC. Non e'
--   una svista di Supabase: e' il comportamento normale del database, e vale
--   per ogni CREATE FUNCTION scritto dal SQL Editor, da una migration o da
--   una chat. Su Supabase si somma il fatto che anon e authenticated sono
--   ruoli veri e la chiave anon sta in chiaro in ogni pagina del sito.
--   Risultato: ogni nuova RPC nasce chiamabile da chiunque, e resta tale
--   finche' qualcuno non se ne accorge. E' esattamente come sono nate le 114
--   funzioni censite in 00_censimento.md.
--
-- LO STATO DI OGGI, LETTO IL 22 SET DA pg_default_acl
--   Per le funzioni dello schema public:
--     create da postgres        ->  postgres=X  anon=X  authenticated=X  service_role=X
--     create da supabase_admin  ->  postgres=X  anon=X  authenticated=X  service_role=X
--   In queste due righe PUBLIC non compare, mentre le 113 funzioni gia' in
--   essere ce l'hanno. Vuol dire che il default e' stato cambiato a un certo
--   punto, dopo che quelle funzioni erano gia' nate. Resta pero' il GRANT
--   esplicito ad anon, che da solo basta a riaprire la porta.
--   Prima di applicare questo file conviene misurare, non dedurre: la prova
--   sta in fondo, e si fa con una funzione usa e getta.
-- ==========================================================================


-- ─── 1 · Il default: niente PUBLIC, niente anon ───────────────────────────
-- Da qui in avanti una funzione nuova nasce muta: la chiamano solo postgres,
-- service_role e chi riceve un GRANT esplicito.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- authenticated si tiene: la stragrande maggioranza delle RPC di questo
-- progetto serve il portale, cioe' gente loggata. Toglierlo vorrebbe dire un
-- GRANT a mano per ogni funzione nuova, e la regola che costa troppo e' la
-- prima che si salta. Se un giorno si vuole il rigore pieno, la riga e' questa:
--
--   ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--     REVOKE EXECUTE ON FUNCTIONS FROM authenticated;


-- ─── 2 · Lo stesso per le funzioni create da supabase_admin ───────────────
-- Le funzioni scritte dal SQL Editor appartengono a postgres, quindi la
-- sezione 1 basta quasi sempre. Questa e' la cintura.
-- ATTENZIONE: su Supabase il ruolo postgres non e' superuser e potrebbe non
-- avere il diritto di cambiare i default di supabase_admin. Se queste due
-- righe danno 'permission denied', si saltano: non compromettono il resto.

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;


-- ==========================================================================
-- COSA CAMBIA NEL LAVORO DI TUTTI I GIORNI
-- ==========================================================================
-- Da qui in avanti, una RPC che deve servire una pagina pubblica (una landing,
-- un questionario aperto da un link, i conteggi degli slot) non funzionera'
-- finche' non le si concede EXECUTE. Il GRANT diventa il momento in cui
-- qualcuno decide, consapevolmente, che quella funzione e' pubblica:
--
--   GRANT EXECUTE ON FUNCTION public.nome_funzione(tipi...) TO anon;
--
-- E' il punto di tutto il cantiere. Oggi una funzione e' pubblica per
-- distrazione; dopo questo file lo diventa per scelta, e la scelta lascia una
-- riga scritta.
--
-- Da mettere nella lista di controllo di ogni nuova RPC:
--   1. deve girare come SECURITY DEFINER? se no, non metterlo;
--   2. se si', quale guardia ha dentro? (mai auth.uid() = qualcosa: vedi 02_piano.md)
--   3. chi deve chiamarla? serve un GRANT esplicito;
--   4. l'audit di sql/audit-security-definer.sql la promuove?


-- ==========================================================================
-- V-DEFAULT · la prova, da fare prima e dopo
-- ==========================================================================
-- 1. Lo stato dichiarato:

SELECT pg_get_userbyid(d.defaclrole) AS creato_da,
       n.nspname                     AS schema,
       array_to_string(d.defaclacl,' ') AS privilegi_di_default
FROM pg_default_acl d
LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
WHERE d.defaclobjtype = 'f' AND n.nspname = 'public'
ORDER BY 1;

-- 2. Lo stato reale, con una funzione usa e getta.
--    Va eseguita tutta insieme: l'ultima riga la cancella.
--
--    CREATE FUNCTION public._prova_privilegi_191() RETURNS int
--      LANGUAGE sql AS $$ SELECT 1 $$;
--
--    SELECT array_to_string(proacl,' ') AS acl_appena_nata
--    FROM pg_proc WHERE proname = '_prova_privilegi_191';
--
--    DROP FUNCTION public._prova_privilegi_191();
--
--    Prima del 06, atteso qualcosa come:
--      =X/postgres postgres=X/postgres anon=X/postgres authenticated=X/postgres ...
--    Dopo il 06, ne devono sparire l'entry senza nome (PUBLIC) e quella di anon.
--
--    NOTA: questa prova crea e cancella un oggetto. Non l'ho eseguita io,
--    perche' la consegna di DEBITO-191 e' in sola lettura.


-- ==========================================================================
-- COME SI TORNA INDIETRO
-- ==========================================================================
--   ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--     GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
--   ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--     GRANT EXECUTE ON FUNCTIONS TO anon;
--
-- I default non toccano le funzioni gia' esistenti, ne' prima ne' dopo:
-- valgono solo per quelle create da quel momento in poi. Applicare o
-- revocare questo file non puo' rompere niente che sia gia' online.
