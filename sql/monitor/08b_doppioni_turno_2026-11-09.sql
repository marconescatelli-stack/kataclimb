-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08b · DOPPIONI DEL TURNO DI GIAMMARCO, 9 nov 2026 (trovati durante la consegna dei turni dichiarati)
-- NON APPLICATO. Si esegue solo dopo il "vai" di Marco: cambiare ROLLBACK in COMMIT.
--
-- Cosa è successo: il 9/11 alle 19:56:03 per Giammarco Rinauro (77335928…) si sono aperti 7 turni_monitor nello
-- stesso istante (più chiamate insieme a monitor_turno/monitor_segna, nessun blocco). Con la regola di allora ogni
-- turno aperto conta le sue ore: alle 22 la chiusura automatica li chiude tutti e la serata vale 7 volte.
-- Solo uno dei 7 ha una persona seguita (9acb288b…): quello resta. Gli altri 6 si chiudono a 0 minuti (fine = inizio)
-- con la nota, non si cancellano. La migrazione 08 impedisce che succeda di nuovo (blocco per persona all'apertura).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT id, inizio AT TIME ZONE 'Europe/Rome' AS inizio, fine AT TIME ZONE 'Europe/Rome' AS fine,
       (SELECT count(*) FROM turni_monitor_seguiti s WHERE s.turno_id = t.id) AS seguiti
  FROM turni_monitor t
 WHERE t.monitor_user_id = '77335928-3073-42ae-a327-fc2774d1d966' AND t.data = '2026-11-09'
 ORDER BY inizio;

UPDATE turni_monitor t
   SET fine = t.inizio,
       note = CASE WHEN t.note IS NULL OR t.note = '' THEN '' ELSE t.note || E'\n' END
              || '[doppione: aperto 7 volte nello stesso istante il 9/11 alle 19:56; tenuto il turno 9acb288b, questo vale 0 (Marco, sql/monitor/08b)]'
 WHERE t.monitor_user_id = '77335928-3073-42ae-a327-fc2774d1d966' AND t.data = '2026-11-09'
   AND t.id <> '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83'
   AND NOT EXISTS (SELECT 1 FROM turni_monitor_seguiti s WHERE s.turno_id = t.id);

-- verifica: 1 turno con le ore della serata, 6 a zero
SELECT id, round(extract(epoch FROM coalesce(fine, now()) - inizio) / 3600.0, 2) AS ore, note
  FROM turni_monitor
 WHERE monitor_user_id = '77335928-3073-42ae-a327-fc2774d1d966' AND data = '2026-11-09'
 ORDER BY inizio;

ROLLBACK;  -- → COMMIT dopo il "vai" di Marco
