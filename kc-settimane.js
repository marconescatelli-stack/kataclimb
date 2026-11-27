/* ══════════════════════════════════════════════════════════════════════
 * KataClimb — LE MIE SETTIMANE  ·  kc-settimane.js  ·  v1.0 (27 nov 2026)
 * ══════════════════════════════════════════════════════════════════════
 * KC-BUILD: kc-settimane v1.0 · 2026-11-27 · LE MIE SETTIMANE (Marco 27 nov, caso Emanuele Drizzi, "lo farei per tutti";
 *   DB le_mie_settimane_2026_11_27, Master v4.80). UNA sola funzione per il riquadro "Le mie settimane" del profilo
 *   dell'allievo (portale.html) e per "Le sue settimane" della Scheda Allievo (oggi.html): stesso conto, stesse parole.
 *
 * Legge la RPC le_mie_settimane(p_persona_id, p_settimane): una riga per ogni lezione (prenotazione oppure presenza
 * segnata a un iscritto o abbonato) e una per ogni giorno di Sala con Monitor. Qui si raggruppa per settimana
 * (lunedì–domenica), dalla settimana in corso indietro fino alla prima con una presenza, al massimo 8.
 * Solo lettura. Nessun numero salvato: tutto calcolato da quello che già esiste.
 * Date sempre a componenti locali, mai toISOString (trappola 134).
 *
 * Uso:
 *   const r = await kcSettimaneCarica(sb, personaIdONull);      // { righe, errore }
 *   el.innerHTML = kcSettimaneHtml(r.righe, { nomeCorso });      // '' se non c'è niente da mostrare (vedi vuoto)
 */
(function () {
  'use strict';
  var GIORNI = ['domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato'];
  var MESI = ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'];
  var N_SETT = 8;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function dLoc(s) { var p = String(s).slice(0, 10).split('-'); return new Date(+p[0], +p[1] - 1, +p[2]); }
  function iso(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
  function lunedi(d) { var x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return x; }
  function piuGiorni(d, n) { var x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() + n); return x; }
  function intervallo(lun) {
    var dom = piuGiorni(lun, 6);
    return lun.getMonth() === dom.getMonth()
      ? lun.getDate() + '–' + dom.getDate() + ' ' + MESI[dom.getMonth()]
      : lun.getDate() + ' ' + MESI[lun.getMonth()] + ' – ' + dom.getDate() + ' ' + MESI[dom.getMonth()];
  }
  function giornoTesto(s) { var d = dLoc(s); return GIORNI[d.getDay()] + ' ' + d.getDate(); }

  async function kcSettimaneCarica(sb, personaId) {
    try {
      var args = { p_settimane: N_SETT };
      if (personaId) args.p_persona_id = personaId;
      var r = await sb.rpc('le_mie_settimane', args);
      if (r.error) throw r.error;
      return { righe: r.data || [], errore: null };
    } catch (e) {
      console.warn('[le mie settimane]', (e && e.message) || e);
      return { righe: [], errore: (e && e.message) || String(e) };
    }
  }

  /* righe -> [{ lun, lezioni:[...], sala:[...] }] dalla settimana in corso indietro */
  function kcSettimaneRaggruppa(righe, oggi) {
    var lunOggi = lunedi(oggi || new Date());
    var per = {};
    (righe || []).forEach(function (r) {
      var k = iso(lunedi(dLoc(r.giorno)));
      (per[k] = per[k] || { lezioni: [], sala: [] })[r.cosa === 'sala' ? 'sala' : 'lezioni'].push(r);
    });
    var chiavi = Object.keys(per).sort();
    if (!chiavi.length) return [];
    var prima = dLoc(chiavi[0]);
    var limite = piuGiorni(lunOggi, -7 * (N_SETT - 1));
    if (prima < limite) prima = limite;
    var out = [];
    for (var l = lunOggi; l >= prima; l = piuGiorni(l, -7)) {
      var g = per[iso(l)] || { lezioni: [], sala: [] };
      out.push({ lun: l, inCorso: iso(l) === iso(lunOggi), lezioni: g.lezioni, sala: g.sala });
    }
    return out;
  }

  /* opts: nomeCorso(tipo) -> nome intero del corso · vuoto: testo da mostrare se non c'è nessuna riga ('' = niente) */
  function kcSettimaneHtml(righe, opts) {
    opts = opts || {};
    var nomeCorso = opts.nomeCorso || function (t) { return t ? String(t).replace(/_/g, ' ') : 'Lezione'; };
    var oggi = new Date(), oggiIso = iso(oggi);
    var sett = kcSettimaneRaggruppa(righe, oggi);
    if (!sett.length) return opts.vuoto ? '<p style="margin:0;font-size:14px;line-height:1.55;opacity:.8">' + esc(opts.vuoto) + '</p>' : '';
    var riga = function (segno, testo, esito) {
      return '<div style="display:flex;gap:8px;align-items:baseline;font-size:14px;line-height:1.55;margin-top:4px">'
        + '<span style="flex:0 0 18px;text-align:center" aria-hidden="true">' + segno + '</span>'
        + '<span style="flex:1">' + testo + (esito ? ' · <strong>' + esito + '</strong>' : '') + '</span></div>';
    };
    return sett.map(function (s, i) {
      var corpo = '';
      s.lezioni.forEach(function (r) {
        var g = String(r.giorno).slice(0, 10);
        var segno, esito;
        if (r.stato === 'presente') { segno = '✓'; esito = 'presente'; }
        else if (r.stato === 'assente') { segno = '✗'; esito = 'assente'; }
        else if (g >= oggiIso) { segno = '📅'; esito = 'prenotata'; }
        else { segno = '·'; esito = 'presenza non segnata'; }
        corpo += riga(segno, esc(giornoTesto(g)) + ' · ' + esc(nomeCorso(r.corso)) + (r.ora ? ' · ore ' + esc(String(r.ora).slice(0, 5)) : ''), esito);
      });
      if (!s.lezioni.length) corpo += riga('·', s.inCorso ? 'Lezione: ancora nessuna questa settimana' : 'Lezione: nessuna', '');
      if (s.sala.length) {
        corpo += riga('🟢', 'Sala con Monitor · ' + s.sala.map(function (r) { return esc(giornoTesto(r.giorno)); }).join(', '), '');
      }
      return '<div style="padding:10px 0;' + (i ? 'border-top:1px solid rgba(128,128,128,.25)' : 'padding-top:0') + '">'
        + '<div style="font-size:13px;font-weight:700;letter-spacing:.02em">' + (s.inCorso ? 'Questa settimana · ' : '') + esc(intervallo(s.lun)) + '</div>'
        + corpo + '</div>';
    }).join('');
  }

  window.kcSettimaneCarica = kcSettimaneCarica;
  window.kcSettimaneRaggruppa = kcSettimaneRaggruppa;
  window.kcSettimaneHtml = kcSettimaneHtml;
})();
