'use strict';
const $ = id => document.getElementById(id);
let token = '', busy = false;
const labels = {info: '一般通知', important: '重要通知', maintenance: '维护通知'};
function status(message, error = false) { $('status').textContent = message; $('status').className = error ? 'error' : ''; $('status').hidden = !message; }
function logout() { token = ''; $('token').value = ''; $('console').hidden = true; $('login').hidden = false; $('logout').hidden = true; $('items').replaceChildren(); }
async function api(path = '', options = {}) {
  const response = await fetch('/admin/api/notifications' + path, {...options, credentials: 'omit', headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}});
  if (!response.ok) { if (response.status === 401) logout(); throw new Error(await response.text()); }
  return response.status === 204 ? null : response.json();
}
function element(tag, text, className) { const el = document.createElement(tag); el.textContent = text; if (className) el.className = className; return el; }
function confirmAction(title, body) {
  $('confirm-title').textContent = title; $('confirm-body').textContent = body;
  return new Promise(resolve => { $('confirm').returnValue = 'cancel'; $('confirm').addEventListener('close', () => resolve($('confirm').returnValue === 'confirm'), {once:true}); $('confirm').showModal(); });
}
async function refresh() {
  const {items} = await api();
  $('total').textContent = items.length; $('active').textContent = items.filter(n => !n.revoked_at).length; $('revoked').textContent = items.filter(n => n.revoked_at).length;
  $('empty').hidden = items.length > 0; $('items').replaceChildren();
  for (const item of items) {
    const card = element('article', '', 'item' + (item.revoked_at ? ' revoked' : ''));
    const top = element('div', '', 'item-top');
    top.append(element('span', labels[item.level] || item.level, 'badge ' + item.level), element('time', new Date(item.created_at * 1000).toLocaleString('zh-CN')));
    card.append(top, element('h3', item.title), element('p', item.body));
    const bottom = element('div', '', 'item-bottom');
    bottom.append(element('span', item.revoked_at ? '已撤回' : '发布中', 'badge' + (item.revoked_at ? ' revoked' : '')));
    if (!item.revoked_at) {
      const revoke = element('button', '撤回通知', 'revoke');
      revoke.addEventListener('click', () => run(async () => {
        if (!await confirmAction('撤回这条通知？', '“' + item.title + '”将在客户端下次同步时移除。已经显示的系统提醒无法撤回。')) return;
        await api('/' + encodeURIComponent(item.id), {method:'DELETE'});
        status('通知已撤回。'); await refresh();
      }));
      bottom.append(revoke);
    }
    card.append(bottom); $('items').append(card);
  }
}
async function run(action) {
  if (busy) return; busy = true;
  document.querySelectorAll('button:not(dialog button)').forEach(b => b.disabled = true);
  try { await action(); } catch (e) { status(e.message || '请求失败，请检查网络后重试。', true); }
  finally { busy = false; document.querySelectorAll('button').forEach(b => b.disabled = false); }
}
$('login-form').addEventListener('submit', event => { event.preventDefault(); run(async () => {
  token = $('token').value.trim(); await refresh(); $('token').value = ''; $('login').hidden = true; $('console').hidden = false; $('logout').hidden = false; status('');
}); });
function preview() { $('preview-title').textContent = $('title').value.trim() || '通知标题'; $('preview-body').textContent = $('body').value.trim() || '通知内容将在这里显示。'; $('count').textContent = [...$('body').value].length; }
$('title').addEventListener('input', preview); $('body').addEventListener('input', preview);
$('publish-form').addEventListener('submit', event => { event.preventDefault(); run(async () => {
  const draft = {title:$('title').value.trim(), body:$('body').value.trim(), level:$('level').value};
  if (!draft.title || !draft.body) throw new Error('请填写通知标题和正文。');
  if (!await confirmAction('确认发布通知？', '“' + draft.title + '”将发送给所有支持通知的客户端。')) return;
  await api('', {method:'POST', body:JSON.stringify(draft)}); $('publish-form').reset(); preview();
  status('通知已发布，在线客户端将实时收到，离线客户端下次连接时同步。'); await refresh();
}); });
$('refresh').addEventListener('click', () => run(refresh));
$('logout').addEventListener('click', () => { logout(); status('已退出登录。'); });
