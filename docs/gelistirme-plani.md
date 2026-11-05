# LLM uygulamaları — ortak geliştirme planı

Android ve iOS'ta günlük kullanılabilir sohbet, model ve belge yönetimi; yeni teknolojiler için aynı altyapıyı kullanan Laboratuvar.

İşleyiş: bir adım → uygulama → ilgili kontroller → her depoda ayrı commit → kullanıcı tarafından push. Platformlar aynı kullanıcı davranışlarını hedefler; inference motorlarının aynı olması gerekmez.

## 0. Başlangıç kaydı

- [x] Android'deki OCR/GPU deneyleri ve mimari raporu `d53bb60` stash kaydına alındı.
- [x] iOS kişisel Xcode şema ayarı `96461cf` stash kaydına alındı.
- [x] İki depoda `codex/shared-model-sessions` dalı açıldı.

Stash kayıtları yalnızca ilgili yerel depodadır; normal push ile gönderilmez. Eski deneylerin tamamını yeni geliştirmelerin üzerine uygulamak yerine gereken dosyalar ayrı değerlendirilmelidir.

## 1. Model oturumu temelini ayır

- [x] Android model motorları ve oturum sahipliği `inference/` altında toplandı.
- [x] Test ekranının üretim için BenchmarkViewModel çağırması kaldırıldı; oturum açma fonksiyonu dışarıdan veriliyor.
- [x] Benchmark ve test üretimi aynı runtime sahibi üzerinden sıralanıyor; benchmark öncesi sıcak feature oturumu bırakılıyor.
- [x] Aynı modelin LiteRT oturumunu yeniden kullanma, model değişiminde kaynak bırakma ve iptal sonrası lease kapatma tanımlandı.
- [x] iOS model seçimi tanımları ve MLX/Apple oturumu LocalChatModel'den ayrıldı.
- [x] iOS sohbet modeli dışarıdan verilebilen ModelSessionServing arayüzünü kullanıyor; geçmiş ve ekran state'i sohbet modelinde kaldı.
- [x] Android oturum testleri ve iOS sohbet orkestrasyon testleri eklendi.
- [x] Android debug derlemesi ve 33 birim testi; iOS 27 simülatör derlemesi, 5 uygulama testi ve imzasız iOS cihaz hedefi derlemesi geçti.
- [ ] Fiziksel cihazda model seçimi, token akışı, model değişimi ve RAG/ses geçişini kontrol et.
- [ ] Ayrı commit'leri pushla.

Bu adım ekranları yeniden tasarlamaz. Android model seçimi state'i geçici olarak BenchmarkUiState'te kalır; TestRoute bu state'i ve callback'leri alır. Android RAG kendi motorlarını kullanmaya devam eder; ortak runtime'a geçiş belge aşamasında yapılacak. Mevcut BenchmarkPrompt/BenchmarkModelSelection veri tiplerinin tarafsız adlandırılması da ileriki adımda yapılabilir.

İptal, Android'de çağıran coroutine'in, iOS'ta çağıran Task'ın iptaliyle iletilir. Bu servis sözleşmesi, yeni bir kullanıcıya dönük durdur düğmesi eklenmesi anlamına gelmez. Native motorun fiziksel iptal süresi cihaz üzerinde doğrulanmalıdır.

## 2. Sohbeti eşitle

- [ ] Android'e sohbet ekranı ve kalıcı sohbet/mesaj deposu ekle.
- [ ] Model seçimi ve indirme durumunu benchmark ekranından bağımsızlaştır.
- [ ] İki tarafta cevap durdurma, yeniden deneme ve yeniden üretme davranışlarını tamamla.
- [ ] Yeni sohbet, sohbet seçme/silme/adlandırma ve uygulama yeniden açılışını doğrula.
- [ ] Hata ve iptal durumlarında kısmi cevabın nasıl saklandığını ortaklaştır.

## 3. Modelleri eşitle

- [ ] İndirme ilerlemesi, iptal/yeniden deneme ve silme akışlarını tamamla.
- [ ] Model yeteneklerini (üretim, embedding, platform/runtime desteği) açıkça tanımla.
- [ ] Cihaz uyumluluğu ve depolama bilgisini kullanıcıya göster.

## 4. Belgeleri eşitle

- [ ] Parser, chunking, embedding, vektör deposu ve cevap üretimini ayır.
- [ ] Android RAG üretimini ortak runtime üzerinden çalıştır.
- [ ] iOS ağır dosya/indeks işlerini ana aktörden ayır.
- [ ] Kaynak gösterimi ve belge/indeks yaşam döngüsünü eşitle.
- [ ] Veri hacmine göre iOS vektör deposu kararını ölçümle ver.

## 5. Laboratuvarı düzenle

- [ ] Benchmark, embedding karşılaştırması ve yeni deneyleri tek alanda topla.
- [ ] Ortak deney/sonuç şeması: model sürümü, prompt, parametreler, chunking, top-k ve süre tanımları.
- [ ] Soğuk yükleme ile sıcak üretim ölçümlerini ayır.
- [ ] Kaydedilmiş deneyi tekrar çalıştırmayı sağla.
- [ ] Yedekteki OCR/GPU deneylerinden uygun olanları ayrı adımlarla geri getir.

## Adım 1 doğrulama kaydı — 5 Kasım 2026

Android: `./gradlew :app:testDebugUnitTest :app:assembleDebug --offline` başarılı. Toplam 33 test, 0 hata; yeni ModelSessionServiceTest içinde 6 test var. Yeniden kullanım, model değiştirme, hazırlık/üretim iptali, kapatma sırasında aktif üretimi bekleme, soğuk benchmark erişimi ve hata iletimi doğrulandı.

iOS: `xcodebuild -project LLM.xcodeproj -scheme LLM -destination 'platform=iOS Simulator,id=2DF84EFE-3B91-4FA8-82C9-FA2E509CF39A' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test` başarılı. LLMTests altında 5 test, 0 hata. Enjekte edilen servisle token akışı, hazırlık hatası/yeniden deneme, bağlamlı cevap sonrası oturum sıfırlama, iptal sonrası yeni istek ve kaynak bırakma delegasyonu doğrulandı. Başka bilgisayarda destination için mevcut bir iOS 27+ simülatörü seçilmeli.

Ek olarak `generic/platform=iOS` hedefinde `CODE_SIGNING_ALLOWED=NO build` başarılı.

Testler gerçek model ağırlıkları indirmez. Fiziksel cihazdaki native inference performansı, MLX/Apple model geçişi ve mikrofon/TTS bu testlerle doğrulanmış sayılmaz.
