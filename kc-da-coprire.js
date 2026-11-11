/* ════════════════════════════════════════════════════════════════════════
 * KataClimb — DA COPRIRE  ·  kc-da-coprire.js  ·  v1.4 (11 nov 2026)
 * ════════════════════════════════════════════════════════════════════════
 * KC-BUILD: kc-da-coprire v1.4 · 2026-11-11 · TURNO IN CORSO (consegna Marco 11 nov, DB sql/monitor/13): un turno di oggi segnato mentre la fascia
 *   e' in corso vale come giorno stesso dall'ora in corso. Quindi per oggi un'ora libera resta "da coprire" finche' non e' FINITA (prima: finche'
 *   non era iniziata). kcOreLibereMonitor(data, impegni, adessoHm): con adessoHm toglie le ore gia' finite. Nient'altro cambia. CUMULA v1.3 (sotto).
 * KC-BUILD: kc-da-coprire v1.3 · 2026-11-10 · TURNI A POSTERIORI (consegna Marco 10 nov, DB sql/monitor/10): un turno monitor segnato a posteriori
 *   (stato da_confermare, da rivedere dalla segreteria) copre le sue ore come previsto/presente: quelle ore non risultano libere.
 *   Nient'altro cambia. CUMULA v1.2 (sotto).
 * KC-BUILD: kc-da-coprire v1.2 · 2026-11-09 · TURNI MONITOR DICHIARATI A ORE INTERE (consegna Marco 9 nov, DB sql/monitor/08): un turno monitor puo' coprire
 *   solo una parte della fascia (es. Claudia 19–20, Mattia 20–22). La voce monitor della bacheca ora e' una per ogni blocco di ORE LIBERE
 *   (nessun impegno monitor previsto/presente che le copra), e per oggi solo le ore non ancora iniziate (il turno si dichiara prima).
 *   Prima bastava un turno che iniziasse alle 19 per nascondere tutta la serata. Nuova funzione esportata kcOreLibereMonitor(data, impegni, adessoHm),
 *   la stessa che usa la griglia di turni.html. CUMULA v1.1 (sotto).
 * KC-BUILD: kc-da-coprire v1.1 · 2026-11-07 · FESTE DEL SABATO (consegna Marco 7 nov, DB feste_sabato_e_private_bambini): NOMI: prima_lezione_privata → 'Lezione Privata Bambini' (era Prima Lezione Privata Speciale) e festa_sabato → 'Festa ed Esperienza Arrampicata' nelle mappe dei nomi dei corsi, mai il nome tecnico o accorciato.
 *   gli slot festa_sabato hanno una riga in slot_copertura (1 istruttore), quindi v_copertura_lezioni li restituisce
 *   OGNI sabato come scoperti. Qui una riga festa_sabato resta solo se in quella data c'e' una festa prenotata
 *   (prenotazioni_festa stato prenotato) su quello slot; se la lettura delle feste non riesce, nessuna riga festa.
 *   Titolo "Festa del sabato · N bambini". Nient'altro cambia. CUMULA v1.0 (sotto).
 * UNA sola funzione per la bacheca "📌 Da coprire" di turni.html e per la tessera di oggi.html:
 * stesso conto, stesse voci (decisione di Marco 31 ott 2026).
 *
 * Voci, prossimi 14 giorni (da oggi), in ordine di data e ora, mai cose gia' finite:
 *   - monitor : ore della Sala con Monitor senza turno dichiarato (lun–ven 19–22, sabato 14–18, domenica niente), a blocchi (v1.2)
 *   - lezione : lezione dei corsi scoperta (v_copertura_lezioni.coperta = false) o con richiesta di supporto aperta
 *   - scuola  : lezione delle scuole con meno di 3 persone segnate
 * Per ogni voce: chi e' gia' segnato, chi ha detto "sono disponibile" (v_staff_disponibilita), chi non c'e'
 * (v_staff_indisponibilita), se l'utente e' segnato / disponibile / ha segnato "non ci sono", urgente = entro 3 giorni.
 * I monitor (staff_monitor) vedono solo i turni monitor.
 * Solo letture: le scritture restano nelle pagine, via RPC.
 * ════════════════════════════════════════════════════════════════════════ */
(function(){
  /* fasce dei turni monitor per giorno della settimana (Date.getDay(): 0 domenica … 6 sabato) */
  const FASCE_MONITOR_GIORNO={1:{ini:'19:00',fin:'22:00'},2:{ini:'19:00',fin:'22:00'},3:{ini:'19:00',fin:'22:00'},
    4:{ini:'19:00',fin:'22:00'},5:{ini:'19:00',fin:'22:00'},6:{ini:'14:00',fin:'18:00'}};
  const RICHIESTI_SCUOLA=3;
  const GIORNI=14, URGENTE_GIORNI=3;
  const NOME_CORSO={bambini:'Corso Bambini (6–11)',ragazzi:'Corso Ragazzi (12–17)',evo_ragazzi:'Corso Evo Ragazzi',expert:'Corso Expert',genitori:'Corso Genitori KataClimb',
    open:'Corso Open KataClimb',advance:'Corso Advance KataClimb',intro_corda:'Corso Intro Corda KataClimb',evo_corda:'Corso Evo Corda KataClimb',fly:'Corso Fly KataClimb',
    giovani:'Corso Giovani KataClimb (18–24)',senior:'Corso Senior KataClimb (over 60)',manovra_sosta:'Corso Manovra in Sosta KataClimb',
    prima_lezione:'Prima Lezione Adulti',prima_lezione_privata:'Lezione Privata Bambini',festa_sabato:'Festa ed Esperienza Arrampicata',prima_lezione_genitori:'Prima Lezione Genitori',
    prima_lezione_bambini:'Prima Lezione Bambini (6–11)',prima_lezione_ragazzi:'Prima Lezione Ragazzi (12–17)',
    prima_lezione_scuola:'Prima Lezione · Scuole',scuola_mini:'Mini percorso · Scuole'}; // v1.1 festa_sabato: nome completo nella riga sopra
  const FESTA='festa_sabato'; // v1.1
  const pad2=n=>String(n).padStart(2,'0');
  const iso=d=>d.getFullYear()+'-'+pad2(d.getMonth()+1)+'-'+pad2(d.getDate());
  const hm=t=>t?String(t).slice(0,5):'';
  const dLoc=s=>{const[a,m,g]=String(s).slice(0,10).split('-').map(Number);return new Date(a,m-1,g);};
  function nomeCorso(tipo,fascia){
    if(tipo==='bambini')return fascia==='ragazzi'?NOME_CORSO.ragazzi:NOME_CORSO.bambini;
    return NOME_CORSO[tipo]||String(tipo||'Lezione').replace(/_/g,' ');
  }
  function fasciaMonitor(data){ return FASCE_MONITOR_GIORNO[dLoc(data).getDay()]||null; }
  const si=(a,b)=>!a||!b; // ore nulle = tutto il giorno
  /* v1.2 ore intere libere della fascia di quel giorno: blocchi contigui [{ini,fin}] senza turno monitor previsto/presente.
     impegni = righe impegni_staff tipo monitor (data, ora_inizio, ora_fine, stato); adessoHm solo per oggi (ore gia' iniziate escluse). */
  function oreLibereMonitor(data,impegni,adessoHm){
    const f=fasciaMonitor(data); if(!f)return [];
    const h0=Number(f.ini.slice(0,2)), h1=Number(f.fin.slice(0,2)), out=[];
    const attivi=(impegni||[]).filter(x=>x.data===data&&(x.stato==='previsto'||x.stato==='presente'||x.stato==='da_confermare')); // v1.3
    let cur=null;
    for(let h=h0;h<h1;h++){
      const a=pad2(h)+':00', b=pad2(h+1)+':00';
      const coperta=attivi.some(x=>hm(x.ora_inizio)<b&&hm(x.ora_fine)>a);
      const finita=!!adessoHm&&b<=adessoHm; // v1.4: l'ora in corso si puo' ancora prendere
      if(!coperta&&!finita){ if(cur&&cur.fin===a)cur.fin=b; else{ cur={ini:a,fin:b}; out.push(cur); } }
      else cur=null;
    }
    return out;
  }
  const tocca=(x,data,ini,fin)=>x.data===data&&(si(x.ora_inizio,x.ora_fine)||(hm(x.ora_inizio)<hm(fin)&&hm(x.ora_fine)>hm(ini)));

  async function kcDaCoprire(sb,uid,staffRole){
    const oggi=new Date(), oggiIso=iso(oggi), fine=new Date(oggi); fine.setDate(fine.getDate()+GIORNI-1);
    const fineIso=iso(fine), adessoHm=pad2(oggi.getHours())+':'+pad2(oggi.getMinutes());
    const urg=new Date(oggi); urg.setDate(urg.getDate()+URGENTE_GIORNI); const urgIso=iso(urg);
    const [rm,rc,rr,rs,rl,rd,rn,rp,rf]=await Promise.all([
      sb.from('impegni_staff').select('id,user_id,data,ora_inizio,ora_fine,stato').eq('tipo','monitor').neq('stato','ritirato').gte('data',oggiIso).lte('data',fineIso),
      sb.from('v_copertura_lezioni').select('*').gte('data',oggiIso).lte('data',fineIso),
      sb.from('richieste_supporto').select('id,slot_id,data,chiesto_da,note,stato').eq('stato','aperta').gte('data',oggiIso).lte('data',fineIso),
      sb.from('corsi_attivi_settimanali').select('id,tipo_corso,data_evento,ora_inizio,ora_fine,lead_scuola_id').eq('status','attivo')
        .not('lead_scuola_id','is',null).gte('data_evento',oggiIso).lte('data_evento',fineIso),
      sb.from('impegni_staff').select('id,user_id,slot_id,data,ruolo,stato,compenso_tipo').eq('tipo','lezione').in('stato',['previsto','presente']).gte('data',oggiIso).lte('data',fineIso),
      sb.from('v_staff_disponibilita').select('id,user_id,persona,staff_role,tipo,slot_id,data,ora_inizio,ora_fine,nota').lte('data',fineIso),
      sb.from('v_staff_indisponibilita').select('id,user_id,persona,data,ora_inizio,ora_fine,motivo').gte('data',oggiIso).lte('data',fineIso),
      sb.from('profiles').select('user_id,nome,cognome,staff_role').not('staff_role','is',null),
      /* v1.1 feste del sabato prenotate: solo queste rendono "da coprire" uno slot festa_sabato */
      sb.from('prenotazioni_festa').select('slot_id,data,n_bambini').eq('stato','prenotato').gte('data',oggiIso).lte('data',fineIso)
    ]);
    if(rf.error)console.warn('[da coprire] prenotazioni_festa:',rf.error.message);
    const feste=rf.error?[]:(rf.data||[]);
    const festaDi=(slot,data)=>feste.find(f=>f.slot_id===slot&&f.data===data)||null;
    for(const r of [rm,rc,rs,rl]) if(r.error) throw r.error;
    ['richieste_supporto','v_staff_disponibilita','v_staff_indisponibilita','profiles'].forEach((n,i)=>{const r=[rr,rd,rn,rp][i]; if(r.error)console.warn('[da coprire] '+n+':',r.error.message);});
    const nomi={}; (rp.data||[]).forEach(p=>{nomi[p.user_id]=((p.nome||'')+' '+(p.cognome||'')).trim()||'—';});
    const nome=u=>nomi[u]||'—';
    const disp=rd.data||[], indisp=rn.data||[], richieste=rr.data||[], impLez=rl.data||[];
    const finita=(data,fin)=>data===oggiIso&&hm(fin)<=adessoHm;
    function arricchisci(v){
      v.urgente=v.data<=urgIso;
      v.disponibili=disp.filter(d=>d.data===v.data&&hm(d.ora_inizio)===hm(v.ini)&&(v.slot_id?d.slot_id===v.slot_id:!d.slot_id))
        .map(d=>({id:d.id,user_id:d.user_id,persona:d.persona||nome(d.user_id),staff_role:d.staff_role,nota:d.nota}));
      v.mioDisp=(v.disponibili.find(d=>d.user_id===uid)||{}).id||null;
      v.nonDisp=indisp.filter(x=>tocca(x,v.data,v.ini,v.fin)).map(x=>({user_id:x.user_id,persona:nomi[x.user_id]||x.persona||'—',ora_inizio:x.ora_inizio,ora_fine:x.ora_fine}));
      v.ioNonCi=v.nonDisp.some(x=>x.user_id===uid);
      v.mioSegnato=v.segnati.some(s=>s.user_id===uid);
      return v;
    }
    const voci=[];
    /* turni monitor: v1.2 un blocco per ogni gruppo di ore libere (per oggi solo quelle non ancora iniziate) */
    for(let i=0;i<GIORNI;i++){
      const d=new Date(oggi); d.setDate(d.getDate()+i);
      const di=iso(d);
      oreLibereMonitor(di,rm.data||[],di===oggiIso?adessoHm:null).forEach(b=>{
        voci.push(arricchisci({tipo:'monitor',data:di,ini:b.ini,fin:b.fin,slot_id:null,titolo:'Sala con Monitor',segnati:[],conta:'0/1',richiesta:null}));
      });
    }
    /* lezioni dei corsi: scoperte o con richiesta di supporto aperta */
    const viste=new Set();
    (rc.data||[]).forEach(c=>{
      const festa=c.tipo_corso===FESTA?festaDi(c.slot_id,c.data):null; // v1.1
      if(c.tipo_corso===FESTA&&!festa)return;
      const req=c.supporto_richiesto_id?(richieste.find(r=>r.id===c.supporto_richiesto_id)||{id:c.supporto_richiesto_id}):null;
      if((c.coperta&&!req)||finita(c.data,c.ora_fine))return;
      if(req)viste.add(req.id);
      const seg=impLez.filter(x=>x.slot_id===c.slot_id&&x.data===c.data).map(x=>({user_id:x.user_id,nome:nome(x.user_id),ruolo:x.compenso_tipo==='ora'?'assistente':'istruttore'}));
      const ni=Number(c.istruttori||0),na=Number(c.assistenti||0),mi=Number(c.istruttori_min||0),ma=Number(c.assistenti_min||0);
      voci.push(arricchisci({tipo:'lezione',data:c.data,ini:hm(c.ora_inizio),fin:hm(c.ora_fine),slot_id:c.slot_id,
        titolo:nomeCorso(c.tipo_corso,c.fascia)+(festa?` · ${festa.n_bambini} bambini`:''),
        tipo_corso:c.tipo_corso,segnati:seg,conta:`Istruttori ${ni}/${mi}`+(ma||na?` · Assistenti ${na}/${ma}`:''),coperta:!!c.coperta,
        richiesta:req?{id:req.id,chiesto_da:req.chiesto_da,chi:req.chiesto_da?nome(req.chiesto_da):'',note:req.note||''}:null}));
    });
    /* lezioni delle scuole con meno di 3 persone */
    const enti={}, leadIds=[...new Set((rs.data||[]).map(s=>s.lead_scuola_id).filter(Boolean))];
    if(leadIds.length){ const{data}=await sb.from('lead_data').select('id,ente').in('id',leadIds); (data||[]).forEach(l=>{enti[l.id]=l.ente||'';}); }
    (rs.data||[]).forEach(s=>{
      if(finita(s.data_evento,s.ora_fine))return;
      const segR=impLez.filter(x=>x.slot_id===s.id&&x.data===s.data_evento);
      const req=richieste.find(r=>r.slot_id===s.id&&r.data===s.data_evento)||null;
      if(segR.length>=RICHIESTI_SCUOLA&&!req)return;
      if(req)viste.add(req.id);
      voci.push(arricchisci({tipo:'scuola',data:s.data_evento,ini:hm(s.ora_inizio),fin:hm(s.ora_fine),slot_id:s.id,
        titolo:nomeCorso(s.tipo_corso)+(enti[s.lead_scuola_id]?' · '+enti[s.lead_scuola_id]:''),
        segnati:segR.map(x=>({user_id:x.user_id,nome:nome(x.user_id),ruolo:x.ruolo==='conduce'?'conduce':'supporto'})),
        conta:`${segR.length}/${RICHIESTI_SCUOLA}`,richiesta:req?{id:req.id,chiesto_da:req.chiesto_da,chi:req.chiesto_da?nome(req.chiesto_da):'',note:req.note||''}:null}));
    });
    /* richieste di supporto aperte su lezioni non viste sopra */
    const resto=richieste.filter(r=>!viste.has(r.id));
    if(resto.length){
      const{data:ss}=await sb.from('corsi_attivi_settimanali').select('id,tipo_corso,fascia,ora_inizio,ora_fine').in('id',[...new Set(resto.map(r=>r.slot_id))]);
      resto.forEach(r=>{
        const s=(ss||[]).find(x=>x.id===r.slot_id); if(!s||finita(r.data,s.ora_fine))return;
        const seg=impLez.filter(x=>x.slot_id===r.slot_id&&x.data===r.data).map(x=>({user_id:x.user_id,nome:nome(x.user_id),ruolo:x.compenso_tipo==='ora'?'assistente':'istruttore'}));
        voci.push(arricchisci({tipo:'lezione',data:r.data,ini:hm(s.ora_inizio),fin:hm(s.ora_fine),slot_id:r.slot_id,titolo:nomeCorso(s.tipo_corso,s.fascia),
          tipo_corso:s.tipo_corso,segnati:seg,conta:`${seg.length} segnati`,coperta:true,
          richiesta:{id:r.id,chiesto_da:r.chiesto_da,chi:r.chiesto_da?nome(r.chiesto_da):'',note:r.note||''}}));
      });
    }
    let L=voci.sort((a,b)=>(a.data+a.ini).localeCompare(b.data+b.ini));
    if(staffRole==='staff_monitor')L=L.filter(v=>v.tipo==='monitor');
    return {voci:L, urgenti:L.filter(v=>v.urgente).length, conDisponibili:L.filter(v=>v.disponibili.length).length, nomi};
  }

  window.KC_FASCE_MONITOR_GIORNO=FASCE_MONITOR_GIORNO;
  window.kcFasciaMonitor=fasciaMonitor;
  window.kcOreLibereMonitor=oreLibereMonitor; // v1.2
  window.kcDaCoprire=kcDaCoprire;
})();
