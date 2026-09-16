// Builds the contact address in the browser so the HTML served to crawlers never
// contains a harvestable "user@domain" string. Address harvesters overwhelmingly
// regex the raw source; they do not execute page scripts. The two halves live in
// separate attributes and the "@" is assembled from its character code, so no
// pattern in the markup matches an email.
document.querySelectorAll('[data-contact]').forEach(el => {
  const user   = el.getAttribute('data-user');
  const domain = el.getAttribute('data-domain');
  if (!user || !domain) return;

  const address = user + String.fromCharCode(64) + domain;
  const link = document.createElement('a');
  link.href = 'mailto:' + address;
  link.textContent = address;
  el.replaceWith(link);
});
