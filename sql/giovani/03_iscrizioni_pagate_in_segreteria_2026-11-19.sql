-- ════════════════════════════════════════════════════════════════════
-- sql/giovani/03_iscrizioni_pagate_in_segreteria_2026-11-19.sql
-- APPLICATO il 19/11/2026 (prova a secco, poi "vai" di Marco). 67 righe.
--
-- Marco, 19 nov 2026: "tutti i presenti alle lezioni hanno pagato l'iscrizione"; con lo sconto
-- di fine anno gli importi non tornano, quindi niente importo: si registra solo il fatto.
-- Mancava a 67 dei 72 allievi con un abbonamento attivo (iscrizioni_minori): registra_abbonamento
-- non scrive il tesseramento. Senza questa riga il pagamento online del Corso Giovani
-- (giovani_preventivo) e la Lezione Privata Bambini avrebbero chiesto di nuovo l'iscrizione.
-- Chi ha un corso a lezioni (iscrizioni_corso) l'aveva già.
-- ════════════════════════════════════════════════════════════════════
WITH abb AS (SELECT DISTINCT im.persona_id FROM iscrizioni_minori im
              WHERE im.status = 'attiva' AND (im.data_fine IS NULL OR im.data_fine >= current_date))
INSERT INTO tesseramenti (persona_id, anno, data_inizio, data_scadenza, stato, assicurazione, note)
SELECT persona_id, 2026, '2026-11-19', '2026-12-31', 'attivo', true,
       'Iscrizione annuale pagata in segreteria con lo sconto di fine anno: registrata il 19/11/2026 su indicazione di Marco (tutti i presenti alle lezioni hanno pagato l''iscrizione).'
  FROM abb
 WHERE NOT EXISTS (SELECT 1 FROM tesseramenti t WHERE t.persona_id = abb.persona_id AND t.stato = 'attivo' AND t.data_scadenza >= current_date)
ON CONFLICT (persona_id, anno) DO NOTHING;
