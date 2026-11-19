-- ═══════════════════════════════════════════════════════════════════════════
-- QUESTIONARIO "ARRAMPICHI GIÀ" — DOMANDA CLICK UP (decisione di Marco, 19 nov 2026)
-- In Accademia si assicura solo con il Click Up (regolamento). La pagina
-- arrampichi-gia.html v1.7 manda due risposte in più dentro p_risposte:
--   click_up      → "Usa il Click Up"
--   assicuratore  → "Assicura di solito con" (solo chi non lo usa di abitudine)
-- Qui si aggiungono le due etichette, subito dopo "Da primo o da secondo",
-- così le risposte entrano nella nota del diario e nella mail a Marco.
-- Nient'altro cambia nella funzione: il blocco riscrive la definizione che è
-- online sostituendo una sola riga, e si ferma se non la trova una volta sola.
-- Da applicare PRIMA di mettere online arrampichi-gia.html v1.7 (con la pagina
-- vecchia non cambia nulla: le chiavi che non arrivano si saltano).
-- ═══════════════════════════════════════════════════════════════════════════
DO $do$
DECLARE
  v_def text := pg_get_functiondef('public.invia_questionario_arrampicatore(text,text,text,text,jsonb,text,timestamptz)'::regprocedure);
  v_old text := '["ruolo",     "Da primo o da secondo"],';
  v_new text := '["ruolo",     "Da primo o da secondo"],' || E'\n' ||
                '    ["click_up",  "Usa il Click Up"],' || E'\n' ||
                '    ["assicuratore", "Assicura di solito con"],';
BEGIN
  IF position('"click_up"' IN v_def) > 0 THEN
    RAISE NOTICE 'Etichette Click Up già presenti: niente da fare.';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'Riga delle etichette non trovata una volta sola: la funzione è cambiata, fermarsi.';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$do$;
