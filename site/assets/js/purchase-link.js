(() => {
  const config = window.cleanMacPurchaseConfig || {};
  const links = Array.from(document.querySelectorAll('[data-purchase-link]'));
  const message = document.querySelector('[data-purchase-message]');
  const purchaseURL = String(config.purchaseURL || '').trim();

  const setMessage = (text, isError = false) => {
    if (!message) return;
    message.textContent = text;
    message.classList.toggle('is-error', isError);
  };

  const openPurchaseURL = (event) => {
    if (!purchaseURL || purchaseURL === '#buy') {
      event.preventDefault();
      setMessage('淘宝店铺链接尚未配置，请先填写 purchaseURL。', true);
      return;
    }
    setMessage('正在跳转淘宝店铺。下单后请联系客服获取授权码。');
  };

  links.forEach((link) => link.addEventListener('click', openPurchaseURL));

  const params = new URLSearchParams(window.location.search);
  if (params.get(config.autoOpenParam || 'checkout') === (config.autoOpenValue || 'cleanmac') && links[0]) {
    window.setTimeout(() => links[0].click(), 250);
  }
})();
