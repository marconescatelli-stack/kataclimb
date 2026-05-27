/* ════════════════════════════════════════════════════════════════════════
 * KataClimb · Service Worker registration + Push API
 * v3.56b Step 2-4 — esposto come window.KataClimbPush
 *
 * COSA ESPONE
 *   KataClimbPush.getStatus()             → 'unsupported' | 'default' | 'granted' | 'denied'
 *   KataClimbPush.isSubscribed()          → bool (su questo device)
 *   KataClimbPush.requestPermissionAndSubscribe(sbClient) → {ok, reason?}
 *   KataClimbPush.unsubscribe(sbClient)   → {ok}
 *   KataClimbPush.getRegistration()       → ServiceWorkerRegistration | null
 *
 * NOTA: sbClient è il client Supabase (window.sb in portale.html)
 * ════════════════════════════════════════════════════════════════════════ */

(function () {
  let swRegistration = null;

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', async () => {
      try {
        swRegistration = await navigator.serviceWorker.register('/sw.js', { scope: '/' });

        swRegistration.addEventListener('updatefound', () => {
          const newSW = swRegistration.installing;
          if (!newSW) return;
          newSW.addEventListener('statechange', () => {
            if (newSW.state === 'installed' && navigator.serviceWorker.controller) {
              newSW.postMessage({ type: 'SKIP_WAITING' });
            }
          });
        });

        let refreshing = false;
        navigator.serviceWorker.addEventListener('controllerchange', () => {
          if (refreshing) return;
          refreshing = true;
          window.location.reload();
        });
      } catch (e) {
        console.warn('[sw-register]', e);
      }
    });
  }

  // VAPID public key (la privata vive SOLO nel Worker, mai qui)
  const VAPID_PUBLIC_KEY = 'BAx5T6eHYEDMW4mkMsV9jZ5jTp45WKw7MeavJWrHcbOp5GyyaGEySdq_JBqyR8qpD5ERWi92lsM9WB5NOr35foE';

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = window.atob(base64);
    const arr = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
    return arr;
  }

  function detectUserAgentLabel() {
    const ua = navigator.userAgent || '';
    let device = 'Desktop';
    if (/iPhone/.test(ua)) device = 'iPhone';
    else if (/iPad/.test(ua)) device = 'iPad';
    else if (/Android/.test(ua)) device = 'Android';
    else if (/Mac/.test(ua)) device = 'Mac';
    else if (/Windows/.test(ua)) device = 'Windows';

    let browser = 'Browser';
    if (/CriOS|Chrome/.test(ua) && !/Edg/.test(ua)) browser = 'Chrome';
    else if (/Safari/.test(ua) && !/CriOS|Chrome/.test(ua)) browser = 'Safari';
    else if (/Firefox|FxiOS/.test(ua)) browser = 'Firefox';
    else if (/Edg/.test(ua)) browser = 'Edge';

    return device + ' · ' + browser;
  }

  const KCPush = {
    getStatus() {
      if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
        return 'unsupported';
      }
      return Notification.permission;
    },

    async getRegistration() {
      if (swRegistration) return swRegistration;
      if ('serviceWorker' in navigator) {
        swRegistration = await navigator.serviceWorker.ready;
        return swRegistration;
      }
      return null;
    },

    async isSubscribed() {
      try {
        const reg = await this.getRegistration();
        if (!reg) return false;
        const sub = await reg.pushManager.getSubscription();
        return !!sub;
      } catch (e) {
        console.warn('[push] isSubscribed', e);
        return false;
      }
    },

    async getCurrentSubscription() {
      const reg = await this.getRegistration();
      if (!reg) return null;
      return reg.pushManager.getSubscription();
    },

    async requestPermissionAndSubscribe(sbClient) {
      if (this.getStatus() === 'unsupported') {
        return { ok: false, reason: 'unsupported' };
      }

      const perm = await Notification.requestPermission();
      if (perm !== 'granted') {
        return { ok: false, reason: perm };
      }

      const reg = await this.getRegistration();
      if (!reg) return { ok: false, reason: 'no_sw' };

      let sub;
      try {
        sub = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
        });
      } catch (e) {
        console.error('[push] subscribe failed', e);
        return { ok: false, reason: 'subscribe_failed', error: e.message };
      }

      if (!sbClient || !sbClient.rpc) {
        return { ok: false, reason: 'no_supabase_client' };
      }

      const subJson = sub.toJSON();
      try {
        const { data, error } = await sbClient.rpc('upsert_push_subscription', {
          p_endpoint:     subJson.endpoint,
          p_p256dh_key:   subJson.keys.p256dh,
          p_auth_key:     subJson.keys.auth,
          p_user_agent:   navigator.userAgent,
          p_device_label: detectUserAgentLabel(),
        });
        if (error) {
          console.error('[push] DB save failed', error);
          return { ok: false, reason: 'db_save_failed', error: error.message };
        }
        return { ok: true, subscription_id: data?.subscription_id };
      } catch (e) {
        return { ok: false, reason: 'db_exception', error: e.message };
      }
    },

    async unsubscribe(sbClient) {
      const sub = await this.getCurrentSubscription();
      if (!sub) return { ok: true, alreadyUnsubscribed: true };

      const endpoint = sub.endpoint;

      try {
        await sub.unsubscribe();
      } catch (e) {
        console.warn('[push] unsubscribe browser', e);
      }

      if (sbClient && sbClient.rpc) {
        try {
          await sbClient.rpc('delete_push_subscription', { p_endpoint: endpoint });
        } catch (e) {
          console.warn('[push] delete DB', e);
        }
      }

      return { ok: true };
    },
  };

  window.KataClimbPush = KCPush;
})();
