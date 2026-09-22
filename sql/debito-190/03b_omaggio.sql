-- ============================================================================
-- DEBITO-190 · Fase B · 03b — La lezione omaggio diventa un fatto sulla riga
-- Data: 2026-09-22 · Decisione: Marco
--
-- SCOPO
--   Fino a ieri la "lezione regalata" viveva in una spunta dell'interfaccia:
--   agenda.html mandava p_scala_credito = false e la prenotazione, pur valida,
--   non scalava il contatore. Non restava traccia di NIENTE — ne' di chi
--   l'aveva concessa, ne' del perche'. Con i contatori derivati quella spunta
--   non puo' piu' funzionare: la riga E' il consumo.
--   Quindi l'omaggio smette di essere un comportamento e diventa un fatto
--   scritto sulla riga, con chi l'ha concesso e perche'.
--
-- ORDINE: questo file va applicato PRIMA del 01 (che va ri-applicato per
--   vedere le colonne nuove) e PRIMA del 03. Sequenza completa:
--     03b_omaggio.sql  →  01_view_contatori_corso.sql (di nuovo)  →  03_rpc…
--
-- RISCHIO: basso. Aggiunge tre colonne con default, non tocca nessuna riga
--   esistente: tutte le prenotazioni gia' a DB diventano omaggio = false, che
--   e' esattamente quello che sono.
-- ============================================================================

ALTER TABLE public.prenotazioni_corso
  ADD COLUMN IF NOT EXISTS omaggio             boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS omaggio_concesso_da uuid,
  ADD COLUMN IF NOT EXISTS omaggio_motivo      text;

COMMENT ON COLUMN public.prenotazioni_corso.omaggio IS
  'DEBITO-190: la lezione e'' un omaggio. Occupa il posto nello slot e compare '
  'in agenda come tutte le altre, ma non erode il pacchetto: contatori_corso '
  'la tiene fuori da "consumate" e la mostra a parte nella colonna omaggio.';
COMMENT ON COLUMN public.prenotazioni_corso.omaggio_concesso_da IS
  'DEBITO-190: chi ha concesso l''omaggio (auth.uid() al momento della concessione).';
COMMENT ON COLUMN public.prenotazioni_corso.omaggio_motivo IS
  'DEBITO-190: perche''. Obbligatorio quando omaggio = true: senza motivo la '
  'RPC rifiuta. Serve a non ritrovarsi fra un anno con omaggi senza storia.';

-- Cintura: un omaggio senza motivo non deve poter esistere, nemmeno se un
-- domani qualcuno scrivesse sulla tabella senza passare dalle RPC.
ALTER TABLE public.prenotazioni_corso
  DROP CONSTRAINT IF EXISTS prenotazioni_corso_omaggio_motivo_chk;
ALTER TABLE public.prenotazioni_corso
  ADD CONSTRAINT prenotazioni_corso_omaggio_motivo_chk
  CHECK (NOT omaggio OR (omaggio_motivo IS NOT NULL AND btrim(omaggio_motivo) <> ''));

-- Le righe omaggio si cercheranno spesso ("quanti ne abbiamo regalati?"),
-- e sono poche: indice parziale.
CREATE INDEX IF NOT EXISTS prenotazioni_corso_omaggio_idx
  ON public.prenotazioni_corso (user_id, tipo_corso) WHERE omaggio;

-- ============================================================================
-- VERIFICA DOPO L'APPLICAZIONE
-- ============================================================================
-- V1 · Le colonne ci sono e nessuna riga esistente e' stata toccata:
--   SELECT count(*) AS righe_totali,
--          count(*) FILTER (WHERE omaggio) AS omaggio,
--          count(*) FILTER (WHERE omaggio_motivo IS NOT NULL) AS con_motivo
--   FROM public.prenotazioni_corso;
--   Atteso: righe_totali invariato (236 il 22 set), omaggio 0, con_motivo 0.
--
-- V2 · Il vincolo morde:
--   BEGIN;
--   UPDATE public.prenotazioni_corso SET omaggio = true WHERE id = (SELECT id FROM public.prenotazioni_corso LIMIT 1);
--   -- atteso: ERRORE prenotazioni_corso_omaggio_motivo_chk
--   ROLLBACK;
