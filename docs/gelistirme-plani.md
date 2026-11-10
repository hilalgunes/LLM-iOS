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
- [x] Android ilk adım commit’i kullanıcı tarafından pushlandı.
- [ ] iOS dalını ilk kez `git push -u origin codex/shared-model-sessions` ile gönder (upstream henüz tanımlı değil).

İlk adım ekranları yeniden tasarlamadı. İkinci adımda Android sohbet/test model seçimi GenerationModelViewModel ve GenerationModelUiState ile benchmark state’inden ayrıldı. Android RAG kendi motorlarını kullanmaya devam eder; ortak runtime'a geçiş belge aşamasında yapılacak. Mevcut BenchmarkPrompt/BenchmarkModelSelection veri tiplerinin tarafsız adlandırılması da ileriki adımda yapılabilir.

İptal, Android'de çağıran coroutine'in, iOS'ta çağıran Task'ın iptaliyle iletilir. İkinci adımda sohbet ekranlarına kullanıcıya dönük durdurma düğmesi eklendi. Native motorun fiziksel iptal süresi cihaz üzerinde doğrulanmalıdır.

## 2. Sohbeti eşitle

- [x] Android'e sohbet ekranı ve kalıcı sohbet/mesaj deposu ekle.
- [x] Model seçimi ve indirme durumunu benchmark ekranından bağımsızlaştır.
- [x] İki tarafta cevap durdurma, yeniden deneme ve yeniden üretme davranışlarını tamamla.
- [x] Yeni sohbet, sohbet seçme/silme/adlandırma ve uygulama yeniden açılışını doğrula.
- [x] Hata ve iptal durumlarında kısmi cevabın nasıl saklandığını ortaklaştır.

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

## Adım 2 — sohbet ve geçmiş (10 Kasım 2026)

- Android'in başlangıç ekranına Sohbet eklendi. Geçmiş, yeni sohbet, adlandırma, silme, metin seçme/kopyalama ve yeniden üretme bulunuyor.
- Sohbet ve Test için model seçimi/indirme state'i benchmark'tan ayrıldı. Benchmark ayarları kendi ekranında bağımsız kaldı.
- Android konuşmaları model kimliğiyle atomik JSON dosyasında saklanıyor. Yazımlar sıralı; üretim sırasında yaklaşık saniyelik kayıt noktaları ve işlem bitiminde son kayıt var.
- İki platformda iptal/hata sonrası kısmi yanıt ve durum bilgisi korunuyor. Yeniden üretme son kullanıcı sorusunu çoğaltmadan son yanıtı değiştiriyor. Yeni soruların bağlamına tamamlanmamış yanıtlar katılmıyor.
- iOS mesaj kayıtlarına durum alanı eklendi; eski kayıtlar bu alan olmadan da okunuyor. Yarım kalmış üretim yeniden açılışta kesilmiş olarak işaretleniyor.
- Android model başına kalıcı KV-cache iddiası yok: son 8 tamamlanmış mesajdan metin bağlamı oluşturuluyor; mesaj başına 2000 karakter sınırı var. iOS mevcut özetleme davranışını koruyor. Uzun konuşmaların platformlar arası bağlam bütçesi ileride ortaklaştırılacak.

Doğrulama:

- Android: `:app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest --offline` başarılı; toplam 39 birim testi, 0 hata.
- Pixel 10 Pro emülatörü: `ChatScreenTest` (geçmişten açma/adlandırma/silme) ve `EmbeddingNavigationTest` başarılı; 2 ekran testi, 0 hata.
- iOS 27 simülatörü: LLMTests altında 8 test, 0 hata. Eski mesaj şeması, yeniden üretmede soru çoğalmaması, geçmişin tekrar yüklenmesi ve kısmi yanıt saklama dahil.
- Gerçek model ağırlıklarıyla fiziksel cihazda üretim, iptal gecikmesi ve TTS ile birlikte kullanım bu testlerde ölçülmedi.

Sıradaki küçük adım: modeller ekranında indirme/depolama yönetimi ve model yeteneklerinin görünür olması. Mevcut Android RAG motorlarını ortak runtime'a taşıma işi belge aşamasında devam edecek.

### Cihaz kontrolünde görülen ek iş

Pixel 10 Pro'nun 16 KB sayfa boyutlu emülatöründe uygulama açılışında native kütüphaneler için hizalama/uyumluluk uyarısı görüldü. Uygulama uyumluluk modunda açıldı ve sohbet görünümü kontrol edildi. Bu adım native kütüphaneleri değiştirmedi. Sürüm hazırlığından önce bağımlılıkların ve JNI derlemesinin 16 KB uyumluluğu ayrı bir adımda ele alınmalı.
