/* kc-proposta-open.js v1.1 — 17 nov 2026
 * v1.1: sotto il codice QR, "MANDA SU WHATSAPP": apre WhatsApp sul numero dell'allievo con lo stesso link gia' scritto
 *       (per quando l'istruttore non puo' far inquadrare il codice). Il numero si legge da persone.telefono.
 * PROPOSTA OPEN A FINE PRIMA LEZIONE (decisione Marco 17 nov 2026).
 * Appena l'allievo e' segnato presente alla Prima Lezione Adulti, l'istruttore apre questa
 * schermata (da Agenda o da Oggi) e gli fa inquadrare il codice: sul telefono dell'allievo si
 * apre proposta-open.html con il suo link, senza password. In alternativa l'allievo apre il
 * portale e la proposta si apre da sola (portale v3.172).
 * Solo letture (lead_data, persone, profile_data: le stesse che lo staff fa gia'). Nessuna
 * scrittura, nessun pagamento qui dentro. Il codice QR si disegna in pagina con kc-qrcode.js.
 * Il ?v= negli <script> e' obbligatorio: sw.js serve i .js dalla cache.
 * Uso: kcPropostaOpen.apri({ sb, personaId })  oppure  kcPropostaOpen.apri({ sb, leadId })
 */
(function () {
  'use strict';
  var ID = 'kc-po-schermo';
  var qrPronto = null;

  function caricaQr() {
    if (window.qrcode) return Promise.resolve();
    if (qrPronto) return qrPronto;
    qrPronto = new Promise(function (ok, no) {
      var s = document.createElement('script');
      s.src = '/kc-qrcode.js?v=1.4.4';
      s.onload = function () { ok(); };
      s.onerror = function () { qrPronto = null; no(new Error('codice QR non caricato')); };
      document.head.appendChild(s);
    });
    return qrPronto;
  }

  function el(tag, css, testo) {
    var e = document.createElement(tag);
    if (css) e.style.cssText = css;
    if (testo != null) e.textContent = testo;   // mai HTML da nomi di persone
    return e;
  }

  function waNum(tel) {   // stessa regola di oggi.html
    var t = String(tel || '').replace(/[^0-9+]/g, '');
    if (!t) return '';
    t = t.replace(/^\+/, '');
    if (t.indexOf('39') !== 0 && t.length <= 10) t = '39' + t;
    return t;
  }

  function chiudi() {
    var o = document.getElementById(ID);
    if (o) o.remove();
  }

  function schermo() {
    chiudi();
    var o = el('div', 'position:fixed;inset:0;z-index:10000;background:#fff;color:#0A0A0A;overflow-y:auto;' +
      'padding:14px 20px calc(24px + env(safe-area-inset-bottom));font-family:inherit;text-align:center');
    o.id = ID;
    o.setAttribute('role', 'dialog');
    o.setAttribute('aria-modal', 'true');
    o.setAttribute('aria-label', 'Proposta Open');
    var back = el('button', 'display:block;background:none;border:0;font-size:26px;line-height:1;padding:8px 10px 8px 0;cursor:pointer;color:#0A0A0A;font-family:inherit', '←');
    back.type = 'button';
    back.setAttribute('aria-label', 'Torna indietro');
    back.onclick = chiudi;
    o.appendChild(back);
    var corpo = el('div', 'max-width:420px;margin:6px auto 0');
    o.appendChild(corpo);
    document.body.appendChild(o);
    return corpo;
  }

  function titolo(corpo, t) {
    corpo.appendChild(el('div', 'font-size:13px;font-weight:800;letter-spacing:.06em;color:#0284C7;margin-bottom:8px', 'PROPOSTA DEL CORSO OPEN KATACLIMB'));
    corpo.appendChild(el('div', 'font-size:22px;font-weight:900;line-height:1.25;margin-bottom:12px', t));
  }
  function riga(corpo, t, forte) {
    corpo.appendChild(el('p', 'font-size:' + (forte ? '16' : '15') + 'px;line-height:1.55;color:' + (forte ? '#0A0A0A' : '#404040') + ';margin:0 0 12px', t));
  }

  async function apri(opt) {
    opt = opt || {};
    var sb = opt.sb;
    var corpo = schermo();
    riga(corpo, 'Preparo la proposta…');
    try {
      var pid = opt.personaId || null;
      if (!pid && opt.leadId) {
        var r1 = await sb.from('lead_data').select('persona_id').eq('id', opt.leadId).maybeSingle();
        if (r1.error) throw r1.error;
        pid = r1.data && r1.data.persona_id;
      }
      if (!pid) throw new Error('persona non trovata');

      var r2 = await sb.from('persone').select('nome,telefono').eq('id', pid).maybeSingle();
      var nome = ((r2.data && r2.data.nome) || opt.nome || '').trim();
      var chi = nome || 'L’allievo';

      var r3 = await sb.from('profile_data')
        .select('prima_paid,corso_attivo,meta_open_paid,acconto_open_paid')
        .eq('persona_id', pid).limit(1);
      if (r3.error) throw r3.error;
      var pd = (r3.data && r3.data[0]) || null;

      if (!document.getElementById(ID)) return;   // chiusa nel frattempo
      corpo.replaceChildren();

      if (pd && (pd.corso_attivo || pd.meta_open_paid || pd.acconto_open_paid)) {
        titolo(corpo, 'Corso attivo ✓');
        riga(corpo, chi + ' ha già un corso attivo o pagato: la proposta non serve.', true);
        return;
      }
      if (!pd || !pd.prima_paid) {
        titolo(corpo, 'Passa dalla segreteria');
        riga(corpo, 'Nel portale la Prima Lezione di ' + chi + ' non risulta pagata, quindi il pagamento online del Corso Open KataClimb non si apre.', true);
        riga(corpo, 'Cosa fare: accompagna ' + chi + ' in segreteria, l’iscrizione si fa lì.');
        return;
      }

      var url = location.origin + '/proposta-open.html?u=' + encodeURIComponent(pid) +
                (nome ? '&nome=' + encodeURIComponent(nome) : '');
      await caricaQr();
      if (!document.getElementById(ID)) return;
      var qr = window.qrcode(0, 'M');
      qr.addData(url);
      qr.make();

      titolo(corpo, 'Fai inquadrare questo codice a ' + chi);
      riga(corpo, 'Sul suo telefono si apre la sua proposta: calendario, 2 volte a settimana (215 €) oppure 1 volta a settimana (115 € adesso, 100 € dopo le prime 4 lezioni).');
      var box = el('div', 'width:min(78vw,300px);margin:6px auto 14px;padding:10px;border:2px solid #0A0A0A;border-radius:16px;background:#fff');
      box.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true });   // SVG generato dalla libreria, nessun dato in HTML
      var svg = box.querySelector('svg');
      if (svg) { svg.style.width = '100%'; svg.style.height = 'auto'; svg.style.display = 'block'; svg.setAttribute('aria-label', 'Codice QR della proposta Open'); }
      corpo.appendChild(box);
      riga(corpo, 'Accompagna ' + chi + ' fino al pagamento.', true);
      // v1.1 — stesso link su WhatsApp, al numero dell'allievo
      var num = waNum(r2.data && r2.data.telefono);
      if (num) {
        var testo = (nome ? nome + ', ' : '') + 'questa è la tua proposta per continuare con il Corso Open KataClimb. ' +
                    'Apri il link, guarda il calendario e scegli come frequentare: ' + url;
        var wa = el('a', 'display:block;margin:4px 0 6px;background:#0A0A0A;color:#fff;text-decoration:none;font-weight:800;font-size:15px;padding:14px;border-radius:12px', 'MANDA SU WHATSAPP');
        wa.href = 'https://wa.me/' + num + '?text=' + encodeURIComponent(testo);
        wa.target = '_blank';
        wa.rel = 'noopener';
        corpo.appendChild(wa);
        riga(corpo, 'Si apre WhatsApp con il messaggio già scritto per ' + chi + ': premi invia.');
      } else {
        riga(corpo, 'Per mandarla su WhatsApp manca il numero di telefono di ' + chi + ': usa il codice qui sopra.');
      }
    } catch (e) {
      console.error('[proposta open]', e);
      if (!document.getElementById(ID)) return;
      corpo.replaceChildren();
      titolo(corpo, 'Non riesco ad aprire la proposta');
      riga(corpo, 'Il codice non si è caricato (' + ((e && e.message) || 'errore') + ').', true);
      riga(corpo, 'Cosa fare: torna indietro e riprova. Se non va, fai aprire il portale all’allievo: la proposta si apre da sola.');
    }
  }

  window.kcPropostaOpen = { apri: apri, chiudi: chiudi };
})();
