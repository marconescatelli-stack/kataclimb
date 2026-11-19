-- ═══════════════════════════════════════════════════════════════════════════
-- PERSONE DI INTERESSE — lista fissa per i monitor (decisione di Marco, 19 nov 2026)
-- Nata dal caso Chicca Savino: "può fare corda, ma solo con un monitor presente
-- in sala". Sono le persone su cui chi è in sala deve stare attento (sicurezza).
-- Lista corta, sempre visibile allo staff su Oggi (pannello del turno e
-- "Chi segui stasera?"). La vede solo lo staff, mai l'allievo.
-- L'avviso "è entrata in sala adesso" (notifica) è un passo successivo, sopra
-- questa stessa lista.
-- Da applicare al DB di produzione (migrazione persone_di_interesse_2026_11_19)
-- PRIMA di mettere online oggi.html v2.67. Senza, la pagina non mostra nulla
-- e niente si rompe.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.persone_interesse (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id   uuid NOT NULL REFERENCES public.persone(id),
  attenzione   text NOT NULL CHECK (length(trim(attenzione)) >= 5),
  creato_da    uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  ritirato_at  timestamptz,          -- mai cancellata: si ritira e resta la traccia
  ritirato_da  uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS persone_interesse_attive_uq
  ON public.persone_interesse (persona_id) WHERE ritirato_at IS NULL;

ALTER TABLE public.persone_interesse ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS persone_interesse_staff_select ON public.persone_interesse;
CREATE POLICY persone_interesse_staff_select ON public.persone_interesse
  FOR SELECT TO authenticated USING (is_staff());
REVOKE ALL ON public.persone_interesse FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.persone_interesse FROM authenticated;
GRANT SELECT ON public.persone_interesse TO authenticated;

-- Lettura per lo staff: l'elenco attivo, con nome mostrato e foto di riconoscimento.
CREATE OR REPLACE FUNCTION public.persone_di_interesse()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $f$
  SELECT CASE WHEN auth.uid() IS NULL OR NOT is_staff() THEN '[]'::jsonb ELSE coalesce(jsonb_agg(jsonb_build_object(
    'persona_id', pe.id, 'nome', pe.nome, 'cognome', pe.cognome,
    'foto_path', pe.foto_riconoscimento_path, 'attenzione', pi.attenzione
  ) ORDER BY pe.nome, pe.cognome), '[]'::jsonb) END
  FROM persone_interesse pi JOIN persone pe ON pe.id = pi.persona_id
  WHERE pi.ritirato_at IS NULL;
$f$;
REVOKE ALL ON FUNCTION public.persone_di_interesse() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.persone_di_interesse() TO authenticated;

-- Primo elenco, dalle note di Marco sulle schede (registro 7 ago 2026 + 19 nov).
INSERT INTO public.persone_interesse (persona_id, attenzione, creato_da) VALUES
 ('f7fde33c-273f-4bd6-bd92-f88440f4522f', 'Corda solo con un monitor presente in sala. Senza monitor in sala, niente corda.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('b2ba738f-8425-4189-8544-ede582f505f2', 'Su corda ha bisogno di assistenza. In sala è autonomo.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('6c8f9865-04ca-42f0-b365-cff91a5efb63', 'Su corda ha bisogno di assistenza. In sala è autonoma.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('67da0051-8a53-4d1b-9878-42f5ec664507', 'Meglio con un monitor vicino. Non è certificata per la corda.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('9329d043-60d1-45f5-a424-85c539c105bd', 'Autonomo in sala. Non su corda.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('8b57a389-7072-49c7-934d-a3b59b010c70', 'Non indipendente né in sala né su corda: va seguita.', '27b04151-93a7-4ecc-824c-fe337cc631a6'),
 ('a3eb832c-1206-4898-b437-d140d39984e0', 'Non indipendente né in sala né su corda: va seguito.', '27b04151-93a7-4ecc-824c-fe337cc631a6')
ON CONFLICT DO NOTHING;
