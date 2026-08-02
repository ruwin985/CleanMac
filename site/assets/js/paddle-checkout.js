(() => {
  const config = window.cleanMacPaddleConfig || {};
  const buttons = Array.from(document.querySelectorAll('[data-paddle-checkout]'));
  const message = document.querySelector('[data-paddle-message]');

  const setMessage = (text, isError = false) => {
    if (!message) return;
    message.textContent = text;
    message.classList.toggle('is-error', isError);
  };

  const hasCheckoutConfig = () => Boolean(config.clientToken && config.priceID);
  const isLocalProductionCheckout = () => {
    const localHosts = ['localhost', '127.0.0.1', '::1'];
    return config.environment === 'production' && localHosts.includes(window.location.hostname);
  };

  const openCheckout = () => {
    if (!hasCheckoutConfig()) {
      setMessage('购买入口正在配置中：请稍后刷新页面，或先下载试用版。', true);
      return;
    }

    if (isLocalProductionCheckout()) {
      setMessage('Paddle 生产环境不能在 localhost 完成购买测试。请部署到已通过 Paddle 审批的线上域名，或本地改用 sandbox。', true);
      return;
    }

    if (!window.Paddle?.Checkout?.open) {
      setMessage('Paddle Checkout 正在加载，请稍后再试。', true);
      return;
    }

    window.Paddle.Checkout.open({
      items: [{ priceId: config.priceID, quantity: 1 }],
      settings: {
        displayMode: 'overlay',
        theme: 'light',
        locale: 'zh-Hans'
      }
    });
  };

  const initializePaddle = () => {
    if (!hasCheckoutConfig()) {
      buttons.forEach((button) => button.setAttribute('aria-disabled', 'true'));
      return;
    }

    if (!window.Paddle?.Initialize) {
      window.setTimeout(initializePaddle, 120);
      return;
    }

    if (config.environment === 'sandbox' && window.Paddle.Environment?.set) {
      window.Paddle.Environment.set('sandbox');
    }

    window.Paddle.Initialize({
      token: config.clientToken,
      eventCallback: (event) => {
        if (event?.name === 'checkout.error') {
          setMessage('Paddle Checkout 初始化失败，请确认线上域名已审批且已配置默认付款链接。', true);
          console.warn('[CleanMac] Paddle checkout error', event);
        }
      }
    });

    if (isLocalProductionCheckout()) {
      setMessage('当前是本地预览；生产购买链接需部署到 Paddle 审批通过的线上域名后测试。', true);
      return;
    }

    const params = new URLSearchParams(window.location.search);
    if (params.get(config.autoOpenParam || 'checkout') === (config.autoOpenValue || 'cleanmac')) {
      window.setTimeout(openCheckout, 250);
    }
  };

  buttons.forEach((button) => button.addEventListener('click', openCheckout));
  initializePaddle();
})();
