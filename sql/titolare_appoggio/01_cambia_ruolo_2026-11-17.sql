-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/titolare_appoggio/01 · TITOLARE O D'APPOGGIO FINO A 7 GIORNI INDIETRO (Marco, 17 nov 2026)
-- MIGRAZIONE. Si applica solo dopo il "vai" di Marco. Prova: 01_cambia_ruolo_PROVA.sql (BEGIN → questo corpo →
-- verifiche → ROLLBACK).
--
-- Perché: la consegna del 13/11 chiedeva che l'istruttore dichiarasse titolare o d'appoggio sulla propria lezione
-- fino a 7 giorni indietro. Le pagine usavano impegno_mi_segno, che a chi non è segreteria rifiuta le date passate
-- ("data nel passato"). Quindi Turni v1.16 mostrava i bottoni solo da oggi in avanti.
--
-- Cosa cambia:
--  1. FUNZIONE NUOVA impegno_cambia_ruolo(p_impegno_id, p_ruolo). Cambia SOLO impegni_staff.ruolo (conduce = titolare,
--     supporto = d'appoggio) e updated_at di un impegno che c'è già. Non crea, non toglie, non tocca stato,
--     compenso_tipo, presenze, segnato_da.
--     - Segreteria: qualsiasi impegno di lezione non ritirato (come già può fare con impegno_mi_segno).
--     - Istruttore (staff_istruttore_*): solo il proprio impegno, solo nei corsi con titolare (tipo bambini, anche
--       con fascia ragazzi, ed evo_ragazzi, dal 1/11/2026: gli stessi di _istruttore_da_assistente), dalla data di
--       oggi (ora di Roma) meno 7 giorni in avanti.
--  2. impegno_mi_segno NON si tocca: resta com'è, anche il blocco "data nel passato" per segnarsi.
--  Compensi: nessuna modifica alle viste. v_compenso_lezioni legge già ruolo tramite _istruttore_da_assistente,
--  quindi il cambio si vede da solo nel calcolo.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.impegno_cambia_ruolo(p_impegno_id uuid, p_ruolo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  i public.impegni_staff;
  v_tipo_corso text;
  v_oggi date := (now() at time zone 'Europe/Rome')::date;
begin
  if auth.uid() is null or not public.is_staff() then raise exception 'solo staff'; end if;
  if p_ruolo is null or p_ruolo not in ('conduce','supporto') then
    raise exception 'ruolo non valido: conduce (titolare) o supporto (d''appoggio)';
  end if;
  select * into i from public.impegni_staff where id = p_impegno_id for update;
  if not found then raise exception 'impegno non trovato'; end if;
  if i.tipo <> 'lezione' then raise exception 'il ruolo si cambia solo sulle lezioni dei corsi'; end if;
  if i.stato = 'ritirato' then raise exception 'questo impegno è stato ritirato'; end if;
  if not public.is_segreteria() then
    if i.user_id is distinct from auth.uid() then raise exception 'puoi cambiare solo il tuo ruolo'; end if;
    if not exists (select 1 from public.profile_data where user_id = auth.uid() and staff_role like 'staff_istruttore%') then
      raise exception 'titolare o d''appoggio vale solo per gli istruttori';
    end if;
    select tipo_corso into v_tipo_corso from public.corsi_attivi_settimanali where id = i.slot_id;
    if v_tipo_corso is null or v_tipo_corso not in ('bambini','evo_ragazzi') or i.data < date '2026-11-01' then
      raise exception 'in questo corso non c''è titolare o d''appoggio';
    end if;
    if i.data < v_oggi - 7 then
      raise exception 'il ruolo si cambia fino a 7 giorni indietro: per le lezioni più vecchie chiedi alla segreteria';
    end if;
  end if;
  if i.ruolo is distinct from p_ruolo then
    update public.impegni_staff set ruolo = p_ruolo, updated_at = now() where id = i.id;
  end if;
  return jsonb_build_object('ok', true, 'id', i.id, 'data', i.data, 'ruolo', p_ruolo, 'ruolo_prima', i.ruolo,
                            'd_appoggio', public._istruttore_da_assistente(i.id));
end $function$;

REVOKE ALL ON FUNCTION public.impegno_cambia_ruolo(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.impegno_cambia_ruolo(uuid, text) TO authenticated, service_role;
