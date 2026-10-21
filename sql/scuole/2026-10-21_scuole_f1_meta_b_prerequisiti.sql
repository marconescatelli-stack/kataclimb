-- NON ANCORA APPLICATO. Da applicare da chat (Claude, con l'ok di Marco) PRIMA del collaudo della Metà B.
-- Claude Code non scrive sul DB: questo file raccoglie cio' che il codice di portale v3.134 / agenda v3.99 / scuola v1.0
-- da' per esistente e che il 21 ott 2026 a DB mancava (verificato in sola lettura su pg_policies e information_schema).
--
-- 1) richieste_scuole ha RLS attiva e NESSUNA policy: lo staff non la legge (il tab Scuole mostrerebbe "Nessuna richiesta")
--    e non puo' annullarla. Le scritture dal sito passano da inserisci_richiesta_scuola (SECURITY DEFINER): invariate.
-- 2) crm_relazioni ha RLS attiva e NESSUNA policy: lo staff non legge referenti e allievi della scuola
--    (il portale finora la leggeva solo via get_famiglia, SECURITY DEFINER). Qui solo lettura staff.
-- 3) slot_staff (consegna §7b) non esiste. Definizione come da consegna: staff legge tutto, ogni istruttore
--    inserisce/cancella solo la propria riga, segreteria (staff_creator, staff_segreteria) tutto.
--
-- Da sapere: v_scuola_me filtra su mio_lead_scuola(), quindi per lo staff e' vuota anche con ?lead_scuola_id=eq.
-- Il portale non la usa per lo staff: i conteggi li fa sulle tabelle.

-- 1) richieste_scuole: lettura e aggiornamento per lo staff
create policy richieste_scuole_staff_select on public.richieste_scuole
  for select to authenticated using (public.is_staff());
create policy richieste_scuole_staff_update on public.richieste_scuole
  for update to authenticated using (public.is_staff()) with check (public.is_staff());

-- 2) crm_relazioni: lettura per lo staff
create policy crm_relazioni_staff_select on public.crm_relazioni
  for select to authenticated using (public.is_staff());

-- 3) slot_staff: chi si segna sugli slot (scuole oggi, turni monitor domani)
create table public.slot_staff (
  slot_id    uuid not null references public.corsi_attivi_settimanali(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  ruolo      text not null default 'supporto' check (ruolo in ('conduce','supporto')),
  created_at timestamptz not null default now(),
  unique (slot_id, user_id)
);
alter table public.slot_staff enable row level security;

create policy slot_staff_staff_select on public.slot_staff
  for select to authenticated using (public.is_staff());
create policy slot_staff_self_insert on public.slot_staff
  for insert to authenticated with check (public.is_staff() and user_id = auth.uid());
create policy slot_staff_self_delete on public.slot_staff
  for delete to authenticated using (user_id = auth.uid());
create policy slot_staff_segreteria_all on public.slot_staff
  for all to authenticated
  using (exists (select 1 from public.profile_data where user_id = auth.uid() and staff_role in ('staff_creator','staff_segreteria')))
  with check (exists (select 1 from public.profile_data where user_id = auth.uid() and staff_role in ('staff_creator','staff_segreteria')));

grant select, insert, delete on public.slot_staff to authenticated;
