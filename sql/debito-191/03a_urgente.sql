-- ==========================================================================
-- DEBITO-191 · 03a · URGENTE — dati personali e minori
--
-- ##########################################################################
-- #  APPLICATO IN PRODUZIONE il 22 settembre 2026 alle 19:47, da Marco,    #
-- #  dal SQL Editor di Supabase. Le tre verifiche sono passate:            #
-- #    · V-ACL: 13 righe 'authenticated + service_role', nessun'altra      #
-- #    · V-ANON: get_leads_da_contattare respinta con 42501                #
-- #    · flusso pubblico e orari.html funzionanti                          #
-- #  NON va riapplicato. Se serve rifarlo e' comunque ripetibile: REVOKE   #
-- #  e GRANT sugli stessi ruoli lasciano lo stesso stato.                  #
-- #  Per tornare indietro:  GRANT EXECUTE ON FUNCTION <firma> TO anon;     #
-- ##########################################################################
--
-- Sottoinsieme del 03: solo le funzioni che espongono dati di persone o di
-- minori E che nessuna pagina pubblica chiama. Si applica da solo e non tocca
-- una riga di logica. Misurato il 22 set, da anon e senza token:
--   SET ROLE anon; SELECT count(*) FROM get_leads_da_contattare();  -->  410
--
-- Si revoca da PUBLIC e da anon: queste funzioni hanno EXECUTE su PUBLIC
-- (l'entry =X/postgres, senza nome). Finche' PUBLIC ce l'ha, anon esegue
-- lo stesso e un REVOKE al solo anon non chiude niente.
--
-- ─── DA PROTEGGERE CON GUARDIA, NON CON REVOKE ───────────────────────────
-- Espongono dati di persone, minori compresi, ma le chiama una pagina
-- pubblica: revocarle spegne il sito. Serve un filtro sul contenuto.
--   get_eventi_calendario()      orari.html, eventi.html
--       revocandola: sparisce la striscia "Prossimi eventi" dalle pagine
--       pubbliche. Da' nome e iniziale dei primi 5 iscritti a ogni evento.
--   get_evento_pubblico(text)    evento.html, 73_KataCamp.html
--       revocandola: la pagina di ogni evento e del KataCamp resta bianca.
--       Da' le etichette di iscritti e interessati.
--   -> per queste due il problema non e' chi chiama, e' cosa restituiscono:
--      non passano da persona_visibile_community, il filtro di DEBITO-187-B
--      che tiene fuori i minori senza consenso. Decisione aperta.
--   get_persona_per_completamento(uuid), completa_contatti_persona(...)
--       completa-contatti.html, link via email: chi lo riceve non potrebbe
--       piu' lasciare i suoi contatti.
--   get_questionario_prima_context(uuid), salva_questionario_prima(...)
--       questionario-prima.html, stesso caso: il questionario non si apre.
--   listino_gate(uuid)           listino-corsi-bambini/ragazzi con ?u=
--       i due listini mostrerebbero il cancello anche a chi ha il link buono.
--
-- NOTA: inserisci_minore_con_referente e crea_figlio_lead NON sono qui. Le
-- chiamano solo agenda, portale e commerciale, tutte dietro login, quindi si
-- revocano senza rompere niente. crea_figlio_lead tiene service_role perche'
-- la usa il Worker del webhook Stripe.
-- ==========================================================================

BEGIN;

-- chiamanti: commerciale.html:775, portale.html:4497 · anagrafica di ogni contatto
REVOKE EXECUTE ON FUNCTION public.get_leads_da_contattare() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_leads_da_contattare() TO authenticated, service_role;

-- chiamanti: commerciale.html:780 · nome, cognome, telefono, email di ogni allievo
REVOKE EXECUTE ON FUNCTION public.get_cruscotto_percorsi() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_cruscotto_percorsi() TO authenticated, service_role;

-- chiamanti: nessuno nel repo · la storia completa di una persona
REVOKE EXECUTE ON FUNCTION public.get_timeline_persona(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_timeline_persona(uuid) TO authenticated, service_role;

-- chiamanti: portale.html:5091 · il nucleo familiare, genitori e figli
REVOKE EXECUTE ON FUNCTION public.get_famiglia(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_famiglia(uuid, uuid) TO authenticated, service_role;

-- chiamanti: portale.html:5103 · i consensi di un minore
REVOKE EXECUTE ON FUNCTION public.get_consensi_minore(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_consensi_minore(uuid) TO authenticated, service_role;

-- chiamanti: portale.html:5115 · scrive i consensi di un minore
REVOKE EXECUTE ON FUNCTION public.imposta_consenso_minore(uuid, text, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.imposta_consenso_minore(uuid, text, boolean, text) TO authenticated, service_role;

-- chiamanti: nessuno nel repo · allega il documento di consenso di un minore
REVOKE EXECUTE ON FUNCTION public.allega_documento_consenso(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.allega_documento_consenso(uuid, text) TO authenticated, service_role;

-- chiamanti: agenda.html:1355 · nome e cognome dei minori iscritti, per slot
REVOKE EXECUTE ON FUNCTION public.get_iscritti_minori() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_iscritti_minori() TO authenticated, service_role;

-- chiamanti: agenda.html:2399, portale.html:4173 · crea un minore e il suo referente
REVOKE EXECUTE ON FUNCTION public.inserisci_minore_con_referente(text, text, text, text, text, text, text, date, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.inserisci_minore_con_referente(text, text, text, text, text, text, text, date, text) TO authenticated, service_role;

-- chiamanti: commerciale.html:364 · crea il figlio di un lead · Worker Stripe
REVOKE EXECUTE ON FUNCTION public.crea_figlio_lead(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.crea_figlio_lead(uuid, text, text, text) TO authenticated, service_role;

-- chiamanti: portale.html:4794 · scheda di conduzione, risposte personali
REVOKE EXECUTE ON FUNCTION public.get_qualifica_lead(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_qualifica_lead(uuid) TO authenticated, service_role;

-- chiamanti: portale.html:5388 · le note lasciate nel modulo, con canale e pagina
REVOKE EXECUTE ON FUNCTION public.get_richieste_lead(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_richieste_lead(uuid) TO authenticated, service_role;

-- chiamanti: portale.html:5080 · i tesseramenti di un utente qualsiasi
REVOKE EXECUTE ON FUNCTION public.get_tesseramenti(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_tesseramenti(uuid) TO authenticated, service_role;

COMMIT;

-- ─── V-ACL · atteso: 13 righe 'authenticated + service_role', nessun'altra ──
SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS funzione,
  CASE WHEN p.proacl IS NULL                              THEN 'PUBLIC (ACL non impostata)'
       WHEN array_to_string(p.proacl,' ') ~ '(^| )=X/'     THEN 'PUBLIC ha ancora EXECUTE'
       WHEN array_to_string(p.proacl,' ') LIKE '%anon=X%'  THEN 'aperta ad anon'
       WHEN array_to_string(p.proacl,' ') LIKE '%authenticated=X%' THEN 'authenticated + service_role'
       ELSE 'chiusa' END AS chi_puo_chiamarla,
  array_to_string(p.proacl,' ') AS acl_completa
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'get_leads_da_contattare','get_cruscotto_percorsi','get_timeline_persona','get_famiglia',
  'get_consensi_minore','imposta_consenso_minore','allega_documento_consenso','get_iscritti_minori',
  'inserisci_minore_con_referente','crea_figlio_lead','get_qualifica_lead','get_richieste_lead',
  'get_tesseramenti')
ORDER BY chi_puo_chiamarla, funzione;

-- ─── V-ANON · la prova che adesso rifiuta ─────────────────────────────────
-- Sessione a parte: la SELECT fallisce apposta e abortirebbe il resto.
-- Prima del 03a risponde 410. Dopo:
--   ERROR 42501: permission denied for function get_leads_da_contattare
SET ROLE anon;
SELECT count(*) AS righe_lette_da_anon FROM get_leads_da_contattare();
RESET ROLE;

-- Il flusso pubblico, che deve continuare a rispondere anche dopo il 03a:
--   SET ROLE anon;
--   SELECT count(*) FROM get_eventi_calendario();
--   SELECT get_evento_pubblico('kcamp-73') IS NOT NULL;
--   SELECT count(*) FROM conteggi_prima_lezione(current_date, current_date + 30);
--   RESET ROLE;
