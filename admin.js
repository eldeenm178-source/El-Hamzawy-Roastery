const SUPABASE_URL = 'https://odwmymujroxztatmkxav.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_BtiZVBJ6puj_gOddR-Adsg_Xqr3Kxox';
const supabaseClient = window.supabase?.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const statuses = ['طلب جديد', 'بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع'];
const fulfillmentStatuses = ['قيد التجهيز', 'مكتمل'];
const orderColumns = 'id,code,created_at,customer,customer_email,phone,normalized_phone,address,delivery_fee,delivery_distance_km,delivery_latitude,delivery_longitude,payment_method,payment_recipient,receipt_path,kashier_transaction_id,notes,items,subtotal,coupon_code,coupon_discount,points_used,discount,total,points_earned,status,fulfillment_status,delivery_status,delivery_user_id,delivered_at';
const productCatalog = window.storeProductCatalog;
const productImages = [...new Set(productCatalog.products.map(product => product.image))];
const $ = id => document.getElementById(id);
const state = { orders: [], selectedOrder: null, refreshTimer: null, productOverrides: new Map(), selectedProduct: null };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
}

function money(value) {
  return `${Number(value || 0).toLocaleString('ar-EG', { maximumFractionDigits: 2 })} جنيه`;
}

function formatDate(value) {
  return new Intl.DateTimeFormat('ar-EG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
}

function showScreen(name) {
  $('login-screen').hidden = name !== 'login';
  $('access-screen').hidden = name !== 'access';
  $('dashboard').hidden = name !== 'dashboard';
  $('sign-out').hidden = name === 'login';
}

function setMessage(id, message) {
  $(id).textContent = message;
}

async function signOut() {
  clearInterval(state.refreshTimer);
  state.refreshTimer = null;
  await supabaseClient.auth.signOut();
  state.orders = [];
  state.selectedOrder = null;
  showScreen('login');
}

async function openDashboard(session) {
  setMessage('login-message', '');
  const { data: admin, error } = await supabaseClient
    .from('store_admins')
    .select('user_id')
    .eq('user_id', session.user.id)
    .maybeSingle();

  if (error) {
    showScreen('login');
    setMessage('login-message', 'تعذر التحقق من صلاحيات المشرف. شغّل إعداد Supabase المحدّث ثم حاول مجددًا.');
    return;
  }
  if (!admin) {
    showScreen('access');
    return;
  }

  $('account-label').textContent = session.user.email || '';
  showScreen('dashboard');
  await Promise.all([loadOrders(), loadCouriers(), loadCoupons(), loadProducts()]);
  clearInterval(state.refreshTimer);
  state.refreshTimer = setInterval(loadOrders, 20000);
}

async function manageCouriers(action, payload = {}) {
  const { data, error } = await supabaseClient.functions.invoke('manage-couriers', {
    body: { action, ...payload }
  });
  if (error) {
    let message = '';
    const response = error.context;
    if (response && typeof response.clone === 'function') {
      try {
        const body = await response.clone().json();
        message = body?.error || '';
      } catch {
        try { message = await response.clone().text(); } catch {}
      }
    }
    if (message === 'An account with this email already exists') {
      message = 'هذا البريد مسجل بالفعل. استخدم بريدًا جديدًا للمندوب أو اطلب ربط الحساب الموجود.';
    }
    throw new Error(message || error.message);
  }
  if (data?.error) throw new Error(data.error);
  return data;
}

async function loadCouriers() {
  $('couriers-body').innerHTML = '<tr><td colspan="3" class="table-message">جارٍ تحميل القائمة...</td></tr>';
  try {
    const { couriers } = await manageCouriers('list');
    $('couriers-body').innerHTML = couriers.length ? couriers.map(courier => `
      <tr><td>${escapeHtml(courier.name || 'مندوب')}</td><td dir="ltr">${escapeHtml(courier.email)}</td><td>${escapeHtml(formatDate(courier.created_at))}</td></tr>`).join('')
      : '<tr><td colspan="3" class="table-message">لا توجد حسابات مندوبين.</td></tr>';
  } catch (error) {
    $('couriers-body').innerHTML = '<tr><td colspan="3" class="table-message">قائمة المندوبين غير متاحة.</td></tr>';
    setMessage('courier-message', `تعذر تحميل حسابات المندوبين: ${error.message}`);
  }
}

function productDetails(product) {
  return { ...product, ...state.productOverrides.get(product.id) };
}

function renderProducts() {
  const query = $('search-products').value.trim().toLocaleLowerCase();
  const products = productCatalog.products
    .map(productDetails)
    .filter(product => !query || `${product.name} ${product.cat}`.toLocaleLowerCase().includes(query));
  $('products-body').innerHTML = products.length ? products.map(product => `
    <tr>
      <td><img class="product-admin-thumbnail" src="assets/products/${encodeURIComponent(product.image).replaceAll('%2F', '/')}" alt="" loading="lazy"></td>
      <td>${escapeHtml(product.name)}</td>
      <td>${escapeHtml(product.cat)}</td>
      <td>${product.price === null ? 'السعر عند الطلب' : `${escapeHtml(money(product.price))}${product.unit === 'kg' ? ' / كيلو' : ''}`}</td>
      <td><button class="coupon-action" type="button" data-edit-product="${product.id}">تعديل</button></td>
    </tr>`).join('') : '<tr><td colspan="5" class="table-message">لا توجد منتجات مطابقة للبحث.</td></tr>';
}

async function loadProducts() {
  $('products-body').innerHTML = '<tr><td colspan="5" class="table-message">جارٍ تحميل المنتجات...</td></tr>';
  const { data, error } = await supabaseClient
    .from('store_product_overrides')
    .select('product_id,name,category,price,image');
  if (error) {
    $('products-body').innerHTML = '<tr><td colspan="5" class="table-message">تعذر تحميل المنتجات.</td></tr>';
    setMessage('product-message', `تعذر تحميل المنتجات: ${error.message}. شغّل supabase-products-migration.sql أولًا.`);
    return false;
  }
  state.productOverrides = new Map((data || []).map(row => [row.product_id, {
    name: row.name,
    cat: row.category,
    price: row.price === null ? null : Number(row.price),
    image: row.image
  }]));
  setMessage('product-message', '');
  renderProducts();
  return true;
}

function openProductEditor(productId) {
  const product = productCatalog.products.find(item => item.id === productId);
  if (!product) return;
  const current = productDetails(product);
  state.selectedProduct = product;
  $('product-dialog-title').textContent = current.name;
  $('product-edit-name').value = current.name;
  $('product-edit-category').value = current.cat;
  $('product-edit-price').value = current.price ?? '';
  $('product-edit-no-price').checked = current.price === null;
  $('product-edit-price').disabled = current.price === null;
  $('product-price-hint').textContent = current.unit === 'kg' ? 'السعر لكل كيلو.' : `السعر للعبوة المحددة (${current.packLabel}).`;
  $('product-edit-image').value = current.image;
  setMessage('product-edit-message', '');
  $('product-dialog').showModal();
}

productCatalog.cats.slice(1).forEach(category => {
  $('product-edit-category').add(new Option(category.name, category.name));
});
productImages.forEach(image => {
  $('product-image-options').append(new Option(image, image));
});

function couponDate(value) {
  return value ? formatDate(value) : 'بدون تاريخ';
}

function renderCoupons(coupons) {
  $('coupons-body').innerHTML = coupons.length ? coupons.map(coupon => {
    const discount = coupon.discount_type === 'percent'
      ? `${Number(coupon.discount_value).toLocaleString('ar-EG')}%`
      : money(coupon.discount_value);
    const scope = coupon.product_names?.length
      ? coupon.product_names.map(escapeHtml).join('، ')
      : 'كل المنتجات';
    const active = coupon.is_active
      ? '<span class="coupon-status-active">مفعّل</span>'
      : '<span class="coupon-status-disabled">متوقف</span>';
    return `<tr>
      <td dir="ltr"><strong>${escapeHtml(coupon.code)}</strong></td>
      <td>${escapeHtml(discount)}</td>
      <td>${scope}</td>
      <td>${escapeHtml(couponDate(coupon.starts_at))}<br>${escapeHtml(couponDate(coupon.expires_at))}</td>
      <td>${active}</td>
      <td><button class="coupon-action" type="button" data-coupon-action="toggle" data-coupon-code="${escapeHtml(coupon.code)}">${coupon.is_active ? 'إيقاف' : 'تفعيل'}</button><button class="coupon-action coupon-action-danger" type="button" data-coupon-action="delete" data-coupon-code="${escapeHtml(coupon.code)}">حذف</button></td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" class="table-message">لا توجد أكواد خصم.</td></tr>';
}

async function loadCoupons() {
  $('coupons-body').innerHTML = '<tr><td colspan="6" class="table-message">جارٍ تحميل الأكواد...</td></tr>';
  const { data, error } = await supabaseClient
    .from('store_coupons')
    .select('code,discount_type,discount_value,product_names,starts_at,expires_at,is_active')
    .order('created_at', { ascending: false });
  if (error) {
    $('coupons-body').innerHTML = '<tr><td colspan="6" class="table-message">تعذر تحميل أكواد الخصم.</td></tr>';
    setMessage('coupon-message', `تعذر تحميل الأكواد: ${error.message}. تأكد من تشغيل supabase-coupons-migration.sql.`);
    return false;
  }
  setMessage('coupon-message', '');
  renderCoupons(data || []);
  return true;
}

async function loadOrders() {
  setMessage('dashboard-message', '');
  $('orders-body').innerHTML = '<tr><td colspan="9" class="table-message">جارٍ تحميل الطلبات...</td></tr>';
  const [{ data, error }, { data: deliveredToday, error: countError }] = await Promise.all([
    supabaseClient
    .from('store_orders')
    .select(orderColumns)
    .order('created_at', { ascending: false })
    .limit(500),
    supabaseClient.rpc('count_store_orders_delivered_today')
  ]);
  $('count-delivered-today').textContent = countError ? '—' : Number(deliveredToday || 0).toLocaleString('ar-EG');

  if (error) {
    $('orders-body').innerHTML = '<tr><td colspan="9" class="table-message">تعذر تحميل الطلبات.</td></tr>';
    setMessage('dashboard-message', `تعذر تحميل الطلبات: ${error.message}`);
    return;
  }
  state.orders = data || [];
  renderOrders();
}

function renderSummary() {
  $('count-all').textContent = state.orders.length.toLocaleString('ar-EG');
  $('count-new').textContent = state.orders.filter(order => order.status === 'طلب جديد').length.toLocaleString('ar-EG');
  $('count-pending').textContent = state.orders.filter(order => order.status === 'بانتظار تأكيد الدفع').length.toLocaleString('ar-EG');
  $('count-confirmed').textContent = state.orders.filter(order => order.status === 'تم تأكيد الدفع').length.toLocaleString('ar-EG');
  $('count-complete').textContent = state.orders.filter(order => order.fulfillment_status === 'مكتمل').length.toLocaleString('ar-EG');
}

function renderOrders() {
  renderSummary();
  const query = $('search-orders').value.trim().toLocaleLowerCase();
  const status = $('filter-status').value;
  const filtered = state.orders.filter(order => {
    const matchesStatus = status === 'all' || order.status === status;
    const searchable = [order.code, order.customer, order.phone, order.normalized_phone].join(' ').toLocaleLowerCase();
    return matchesStatus && (!query || searchable.includes(query));
  });
  $('results-count').textContent = `${filtered.length.toLocaleString('ar-EG')} طلب`;
  $('orders-body').innerHTML = filtered.length ? filtered.map(order => `
    <tr>
      <td><span class="order-code" dir="ltr">${escapeHtml(order.code)}</span></td>
      <td class="customer-cell"><strong>${escapeHtml(order.customer)}</strong><small>${escapeHtml(order.phone)}</small></td>
      <td>${escapeHtml(formatDate(order.created_at))}</td>
      <td>${escapeHtml(paymentLabel(order.payment_method))}</td>
      <td>${escapeHtml(money(order.total))}</td>
      <td><span class="status-badge" data-status="${escapeHtml(order.status)}">${escapeHtml(order.status)}</span></td>
      <td><span class="fulfillment-badge" data-fulfillment="${escapeHtml(order.fulfillment_status)}">${escapeHtml(order.fulfillment_status)}</span></td>
      <td><span class="delivery-badge" data-delivery="${escapeHtml(order.delivery_status)}">${escapeHtml(order.delivery_status)}</span></td>
      <td><button class="details-button" type="button" data-order-id="${escapeHtml(order.id)}">التفاصيل</button></td>
    </tr>`).join('') : '<tr><td colspan="9" class="table-message">لا توجد طلبات مطابقة.</td></tr>';
  document.querySelectorAll('[data-order-id]').forEach(button => button.addEventListener('click', () => showOrder(button.dataset.orderId)));
}

function paymentLabel(value) {
  return ({ cash: 'الدفع عند الاستلام', wallet: 'محفظة إلكترونية', instapay: 'InstaPay', kashier: 'بطاقة بنكية عبر Kashier' })[value] || value;
}

function detail(label, value, wide = false) {
  return `<div class="detail-item${wide ? ' wide' : ''}"><span>${label}</span><strong>${escapeHtml(value || '—')}</strong></div>`;
}

async function showOrder(id) {
  const order = state.orders.find(item => item.id === id);
  if (!order) return;
  state.selectedOrder = order;
  $('dialog-title').textContent = order.code;
  const items = Array.isArray(order.items) ? order.items : [];
  const hasDeliveryLocation = order.delivery_latitude != null && order.delivery_longitude != null
    && Number.isFinite(Number(order.delivery_latitude)) && Number.isFinite(Number(order.delivery_longitude));
  const deliveryMapUrl = hasDeliveryLocation
    ? `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(`${order.delivery_latitude},${order.delivery_longitude}`)}`
    : '';
  $('order-details').innerHTML = `
    <div class="detail-grid">
      ${detail('العميل', order.customer)}
      ${detail('رقم الهاتف', order.phone)}
      ${order.customer_email ? detail('البريد الإلكتروني للدفع', order.customer_email) : ''}
      ${detail('تاريخ الطلب', formatDate(order.created_at))}
      ${detail('طريقة الدفع', paymentLabel(order.payment_method))}
      ${order.kashier_transaction_id ? detail('مرجع معاملة Kashier', order.kashier_transaction_id, true) : ''}
      ${detail('العنوان', order.address, true)}
      ${detail('المستلم', order.payment_recipient, true)}
      ${detail('ملاحظات', order.notes, true)}
      ${detail('إجمالي المنتجات', money(order.subtotal))}
      ${detail('مسافة الطريق', order.delivery_distance_km == null ? '—' : `${Number(order.delivery_distance_km).toLocaleString('ar-EG',{maximumFractionDigits:4})} كم`)}
      ${detail('تكلفة التوصيل', money(order.delivery_fee))}
      ${detail('خصم الكوبون', money(order.coupon_discount))}
      ${detail('خصم الرصيد', money(order.points_used))}
      ${detail('الإجمالي النهائي', money(order.total))}
      ${detail('تنفيذ الطلب', order.fulfillment_status)}
      ${detail('حالة التوصيل', order.delivery_status)}
      ${detail('وقت التوصيل', order.delivered_at ? formatDate(order.delivered_at) : 'لم يتم التوصيل بعد')}
    </div>
    ${deliveryMapUrl ? `<a class="receipt-link" href="${escapeHtml(deliveryMapUrl)}" target="_blank" rel="noopener">فتح موقع العميل على الخريطة</a>` : ''}
    <div class="item-list"><strong>المنتجات</strong>${items.map(item => `<div class="item-line"><span>${escapeHtml(item.name)} — ${escapeHtml(item.weight)} × ${escapeHtml(item.quantity)}</span><strong>${escapeHtml(money(item.subtotal))}</strong></div>`).join('') || '<span>لا توجد تفاصيل للمنتجات.</span>'}</div>
    ${order.receipt_path ? '<a class="receipt-link" id="receipt-link" href="#" target="_blank" rel="noopener">فتح إيصال التحويل</a>' : ''}`;
  const statusSelect = $('order-status');
  const allowedStatuses = order.payment_method === 'cash' ? ['طلب جديد'] : statuses.slice(1);
  statusSelect.innerHTML = allowedStatuses.map(status => `<option value="${escapeHtml(status)}">${escapeHtml(status)}</option>`).join('');
  statusSelect.value = order.status;
  $('status-form').hidden = allowedStatuses.length === 1;
  $('fulfillment-status').value = order.fulfillment_status;
  setMessage('status-message', '');
  setMessage('fulfillment-message', '');
  $('order-dialog').showModal();

  if (order.receipt_path) {
    const { data, error } = await supabaseClient.storage.from('payment-receipts').createSignedUrl(order.receipt_path, 60);
    const receiptLink = $('receipt-link');
    if (data?.signedUrl) receiptLink.href = data.signedUrl;
    else {
      receiptLink.textContent = error ? `تعذر فتح الإيصال: ${error.message}` : 'تعذر فتح الإيصال';
      receiptLink.removeAttribute('href');
    }
  }
}

$('login-form').addEventListener('submit', async event => {
  event.preventDefault();
  const button = $('login-form').querySelector('button[type="submit"]');
  button.disabled = true;
  setMessage('login-message', 'جارٍ تسجيل الدخول...');
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email: $('email').value.trim(), password: $('password').value });
  button.disabled = false;
  if (error) {
    setMessage('login-message', 'تعذر تسجيل الدخول. راجع البريد وكلمة المرور وإعداد Auth في Supabase.');
    return;
  }
  $('password').value = '';
  await openDashboard(data.session);
});

$('sign-out').addEventListener('click', signOut);
$('access-sign-out').addEventListener('click', signOut);
$('refresh-orders').addEventListener('click', loadOrders);
$('refresh-couriers').addEventListener('click', loadCouriers);
$('refresh-coupons').addEventListener('click', loadCoupons);
$('refresh-products').addEventListener('click', loadProducts);
$('search-products').addEventListener('input', renderProducts);
$('products-body').addEventListener('click', event => {
  const button = event.target.closest('[data-edit-product]');
  if (button) openProductEditor(Number(button.dataset.editProduct));
});
$('product-edit-no-price').addEventListener('change', () => {
  $('product-edit-price').disabled = $('product-edit-no-price').checked;
  if ($('product-edit-no-price').checked) $('product-edit-price').value = '';
  else $('product-edit-price').focus();
});
$('close-product-dialog').addEventListener('click', () => $('product-dialog').close());
$('cancel-product-edit').addEventListener('click', () => $('product-dialog').close());
$('product-dialog').addEventListener('click', event => {
  if (event.target === $('product-dialog')) $('product-dialog').close();
});
$('product-edit-form').addEventListener('submit', async event => {
  event.preventDefault();
  const product = state.selectedProduct;
  if (!product) return;
  const button = $('product-edit-form').querySelector('button[type="submit"]');
  const name = $('product-edit-name').value.trim();
  const category = $('product-edit-category').value;
  const image = $('product-edit-image').value.trim();
  const noPrice = $('product-edit-no-price').checked;
  const priceValue = $('product-edit-price').value.trim();
  const price = noPrice ? null : Number(priceValue);
  if (!name) {
    setMessage('product-edit-message', 'اكتب اسم المنتج.');
    return;
  }
  if (!productCatalog.cats.slice(1).some(item => item.name === category)) {
    setMessage('product-edit-message', 'اختر قسمًا صحيحًا للمنتج.');
    return;
  }
  if (!noPrice && (!priceValue || !Number.isFinite(price) || price < 0)) {
    setMessage('product-edit-message', 'اكتب سعرًا صحيحًا لا يقل عن صفر، أو اختر السعر عند الطلب.');
    return;
  }
  if (!productImages.includes(image)) {
    setMessage('product-edit-message', 'اختر صورة موجودة في كتالوج الصور.');
    return;
  }

  button.disabled = true;
  setMessage('product-edit-message', 'جارٍ حفظ التعديلات...');
  const override = { product_id: product.id, name, category, price, image };
  const { error } = await supabaseClient
    .from('store_product_overrides')
    .upsert(override, { onConflict: 'product_id' });
  button.disabled = false;
  if (error) {
    setMessage('product-edit-message', `تعذر حفظ التعديلات: ${error.message}`);
    return;
  }
  state.productOverrides.set(product.id, { name, cat: category, price, image });
  renderProducts();
  $('product-dialog').close();
  setMessage('product-message', `تم حفظ تعديلات ${name}.`);
});
$('coupon-admin-scope').addEventListener('change', () => {
  $('coupon-products-field').hidden = $('coupon-admin-scope').value !== 'selected';
});
$('create-coupon-form').addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget;
  const button = form.querySelector('button[type="submit"]');
  const code = $('coupon-admin-code').value.trim().toUpperCase();
  const discountType = $('coupon-admin-type').value;
  const discountValue = Number($('coupon-admin-value').value);
  const productNames = $('coupon-admin-scope').value === 'selected'
    ? [...new Set($('coupon-admin-products').value.split(/\r?\n/).map(name => name.trim()).filter(Boolean))]
    : [];
  const startsAt = $('coupon-admin-start').value ? new Date($('coupon-admin-start').value).toISOString() : null;
  const expiresAt = $('coupon-admin-expiry').value ? new Date($('coupon-admin-expiry').value).toISOString() : null;

  if (!/^[A-Z0-9_-]{2,40}$/.test(code)) {
    setMessage('coupon-message', 'اكتب كودًا من 2 إلى 40 حرفًا إنجليزيًا أو رقمًا أو شرطة.');
    return;
  }
  if (!Number.isFinite(discountValue) || discountValue <= 0 || (discountType === 'percent' && discountValue > 100)) {
    setMessage('coupon-message', discountType === 'percent' ? 'النسبة يجب أن تكون أكبر من صفر ولا تتجاوز 100%.' : 'اكتب قيمة خصم صحيحة أكبر من صفر.');
    return;
  }
  if ($('coupon-admin-scope').value === 'selected' && !productNames.length) {
    setMessage('coupon-message', 'اكتب اسم منتج واحدًا على الأقل أو اختر تطبيق الكود على كل المنتجات.');
    return;
  }
  if (startsAt && expiresAt && new Date(expiresAt) <= new Date(startsAt)) {
    setMessage('coupon-message', 'تاريخ الانتهاء يجب أن يكون بعد تاريخ البداية.');
    return;
  }

  button.disabled = true;
  setMessage('coupon-message', 'جارٍ إضافة كود الخصم...');
  const { error } = await supabaseClient.from('store_coupons').insert({
    code,
    discount_type: discountType,
    discount_value: discountValue,
    product_names: productNames,
    starts_at: startsAt,
    expires_at: expiresAt
  });
  button.disabled = false;
  if (error) {
    setMessage('coupon-message', error.code === '23505'
      ? 'هذا الكود موجود بالفعل. استخدم كودًا مختلفًا أو احذف القديم أولًا.'
      : `تعذر إضافة كود الخصم: ${error.message}`);
    return;
  }
  form.reset();
  $('coupon-products-field').hidden = true;
  if (await loadCoupons()) setMessage('coupon-message', `تمت إضافة كود ${code}.`);
  else setMessage('coupon-message', `تمت إضافة كود ${code}، لكن تعذر تحديث القائمة: ${$('coupon-message').textContent}`);
});
$('coupons-body').addEventListener('click', async event => {
  const button = event.target.closest('[data-coupon-action]');
  if (!button) return;
  const code = button.dataset.couponCode;
  const action = button.dataset.couponAction;
  if (action === 'delete' && !window.confirm(`هل تريد حذف كود ${code}؟`)) return;
  button.disabled = true;
  setMessage('coupon-message', action === 'delete' ? 'جارٍ حذف الكود...' : 'جارٍ تحديث حالة الكود...');
  const query = supabaseClient.from('store_coupons');
  const result = action === 'delete'
    ? await query.delete().eq('code', code)
    : await query.update({ is_active: button.textContent.trim() === 'تفعيل' }).eq('code', code);
  if (result.error) {
    button.disabled = false;
    setMessage('coupon-message', `تعذر تحديث الكود ${code}: ${result.error.message}`);
    return;
  }
  if (await loadCoupons()) {
    setMessage('coupon-message', action === 'delete' ? `تم حذف كود ${code}.` : `تم تحديث حالة كود ${code}.`);
  } else {
    setMessage('coupon-message', `تم تنفيذ الإجراء على كود ${code}، لكن تعذر تحديث القائمة: ${$('coupon-message').textContent}`);
  }
});
$('create-courier-form').addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget;
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  setMessage('courier-message', 'جارٍ إنشاء حساب المندوب...');
  try {
    const { courier } = await manageCouriers('create', {
      name: $('courier-name').value.trim(),
      email: $('courier-email').value.trim(),
      password: $('courier-password').value
    });
    form.reset();
    setMessage('courier-message', `تم إنشاء حساب ${courier.email} وإضافته إلى لوحة المندوب.`);
    await loadCouriers();
  } catch (error) {
    setMessage('courier-message', `تعذر إنشاء الحساب: ${error.message}`);
  } finally {
    button.disabled = false;
    $('courier-password').value = '';
  }
});
$('search-orders').addEventListener('input', renderOrders);
$('filter-status').addEventListener('change', renderOrders);
$('close-dialog').addEventListener('click', () => $('order-dialog').close());
$('order-dialog').addEventListener('click', event => { if (event.target === $('order-dialog')) $('order-dialog').close(); });
$('status-form').addEventListener('submit', async event => {
  event.preventDefault();
  const order = state.selectedOrder;
  if (!order) return;
  const button = $('status-form').querySelector('button[type="submit"]');
  button.disabled = true;
  setMessage('status-message', 'جارٍ حفظ الحالة...');
  const { error } = await supabaseClient.from('store_orders').update({ status: $('order-status').value }).eq('id', order.id);
  button.disabled = false;
  if (error) {
    setMessage('status-message', `تعذر تحديث الحالة: ${error.message}`);
    return;
  }
  order.status = $('order-status').value;
  $('order-dialog').close();
  await loadOrders();
});

$('fulfillment-form').addEventListener('submit', async event => {
  event.preventDefault();
  const order = state.selectedOrder;
  if (!order) return;
  const button = $('fulfillment-form').querySelector('button[type="submit"]');
  button.disabled = true;
  setMessage('fulfillment-message', 'جارٍ حفظ حالة التنفيذ...');
  const { error } = await supabaseClient.from('store_orders').update({ fulfillment_status: $('fulfillment-status').value }).eq('id', order.id);
  button.disabled = false;
  if (error) {
    setMessage('fulfillment-message', `تعذر تحديث حالة التنفيذ: ${error.message}`);
    return;
  }
  order.fulfillment_status = $('fulfillment-status').value;
  $('order-dialog').close();
  await loadOrders();
});

async function initialize() {
  if (!supabaseClient) {
    setMessage('login-message', 'تعذر تحميل مكتبة Supabase. تحقق من الاتصال بالإنترنت.');
    return;
  }
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (session) await openDashboard(session);
  supabaseClient.auth.onAuthStateChange((_event, session) => {
    if (!session) showScreen('login');
  });
}

initialize();