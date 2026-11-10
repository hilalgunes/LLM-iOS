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
- [x] iOS dalı kullanıcı tarafından pushlandı; upstream tanımlı.

İlk adım ekranları yeniden tasarlamadı. İkinci adımda Android sohbet/test model seçimi GenerationModelViewModel ve GenerationModelUiState ile benchmark state’inden ayrıldı. Android RAG kendi motorlarını kullanmaya devam eder; ortak runtime'a geçiş belge aşamasında yapılacak. Mevcut BenchmarkPrompt/BenchmarkModelSelection veri tiplerinin tarafsız adlandırılması da ileriki adımda yapılabilir.

İptal, Android'de çağıran coroutine'in, iOS'ta çağıran Task'ın iptaliyle iletilir. İkinci adımda sohbet ekranlarına kullanıcıya dönük durdurma düğmesi eklendi. Native motorun fiziksel iptal süresi cihaz üzerinde doğrulanmalıdır.

## 2. Sohbeti eşitle

- [x] Android'e sohbet ekranı ve kalıcı sohbet/mesaj deposu ekle.
- [x] Model seçimi ve indirme durumunu benchmark ekranından bağımsızlaştır.
- [x] İki tarafta cevap durdurma, yeniden deneme ve yeniden üretme davranışlarını tamamla.
- [x] Yeni sohbet, sohbet seçme/silme/adlandırma ve uygulama yeniden açılışını doğrula.
- [x] Hata ve iptal durumlarında kısmi cevabın nasıl saklandığını ortaklaştır.

## 3. Modelleri eşitle

- [x] Android sohbet ve iOS sohbet/embedding modellerinde indirme, iptal, yeniden deneme ve silme kontrollerini ekle.
- [ ] Android eski benchmark/RAG model kataloglarını aynı yönetim akışına taşı.
- [x] Yönetim ekranlarında model amacı ve runtime bilgisini göster.
- [x] Kullanılan disk alanı, boş alan ve eksik dosya durumunu göster.
- [ ] Fiziksel cihaz belleği ve native runtime uyumluluğunu ölçerek model bazında öneri sun.

## 4. Belgeleri eşitle

- [x] Belge okuyucu ve metin parçalama bileşenlerini ayır.
- [ ] Embedding, vektör deposu ve cevap üretimi sınırlarını düzenle.
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

## Adım 3 — model yönetimi (10 Kasım 2026)

- Android sohbet model seçicisi yönetim ekranına dönüştürüldü. Runtime, tahmini boyut, diskte kaplanan alan, boş alan, seçili/hazır/eksik durumları ve silme onayı eklendi. Sohbet geçmişi model silindiğinde korunur.
- Android indirme iptalinde dosya işi tamamlanmadan yeni indirme/silme başlatılmaz. Silme ortak runtime kilidi altında, sıcak oturum kapatıldıktan sonra yapılır; aktif benchmark, test ve RAG işlemlerinde engellenir.
- iOS sohbet ve embedding modellerine Hugging Face önbelleğini kullanan indirme, ilerleme, iptal ve yeniden deneme eklendi. Yönetim sırasında sohbet/RAG işlemleri engellenir; silme native oturumun kaynak bırakmasını bekler. Apple sistem modeli iOS tarafından yönetilir.
- Diskte dosya bulunması tek başına hazır model sayılmaz. Android zorunlu dosyaların boyutunu; iOS aktif snapshot içindeki config, tokenizer ve ağırlıkları (indeks varsa tüm shard dosyalarını) kontrol eder. Bu kontrol modelin cihazda çalışacağı veya dosya içeriğinin geçerli olduğu garantisi değildir.
- Android eski benchmark/RAG kataloglarının birleşmesi, fiziksel cihaz bellek önerileri ve 16 KB native uyumluluk ayrı adımlardır. iOS önbellek tarama/silme işleri hâlâ ana aktörde; büyük önbelleklerde arka plana taşıma açık iştir.

Doğrulama: Android debug derlemesi ve 43 birim testi başarılı. Emülatörde sohbet geçmişi ve yeni model yönetimi penceresini kapsayan 1 ekran testi başarılı. Gerçek model indirme ve fiziksel cihazdaki iptal gecikmesi henüz denenmedi.

iOS: simülatörde 12 test, 0 hata. Eksik blob, tek dosyalı snapshot, eksik/boş shard, model yönetimi sırasında sohbet engeli ve kaynak bırakma delegasyonu doğrulandı. İlk kurulumdaki boş disk alanı düzeltmesinden sonra ayrıca derleme yapıldı. Canlı ağ kesintisi/yeniden başlatma ve gerçek MLX ağırlıklarıyla indirme/silme henüz cihazda denenmedi.

## Adım 4.1 — belge okuyucu ve metin parçalama (10 Kasım 2026)

- Android PDF/TXT okuma kodu RagDocumentReader'a, saf metin parçalama ve belge-parça eşleme kodu RagTextChunker dosyasına taşındı. RAG ekranı okuyucuyu doğrudan çağırır; dosya okuma IO dispatcher üzerinde devam eder.
- iOS PDF/TXT/Markdown/RTF okuma kodu RAGDocumentReading arayüzü ve RAGDocumentReader uygulamasına ayrıldı. LocalRAGModel okuyucuyu dışarıdan alabilir; kaynak kopyalama, dosya erişim izni ve indeks kaydı mevcut import akışında kaldı.
- iOS parçalama RAGTextChunker'a taşındı. PDF sayfa numarası korunur. İki platformda sıfır/negatif parça boyutu ve geçersiz örtüşme açık hatayla reddedilir.
- Mevcut embedding bütçeleri korunur: Android modele göre farklı boyutlar kullanır; iOS 850 karakter / 120 örtüşme kullanır. Android UTF-16 birimleriyle, Swift birleşik karakterlerle böler; bu adım platformlar arasında birebir aynı parça çıktısı veya yeni indeks formatı getirmez.
- Android ortak RAG runtime geçişi, iOS ağır import işlerini arka plana taşıma ve belge/indeks yaşam döngüsü sonraki ayrı commit'lerdir.

Doğrulama: Android debug derlemesi ve 50 birim testi başarılı. Yeni PDF okuma testi bağlı SM-N975F cihazında, Samsung Galaxy S26 Ultra ve Pixel 10 Pro emülatörlerinde geçti (her hedefte 1 test). Test kendi iki sayfalık PDF dosyasını oluşturur; metin sırasını ve bozuk PDF hata davranışını kontrol eder. Gerçek LLM/embedding ağırlıkları indirilmedi.

iOS: derleme başarılı; iPhone 18 Pro / iOS 27 simülatöründe 20 test, 0 hata. Yeni 8 test PDF sayfa bilgisi, UTF-8 Markdown, RTF, bozuk/desteklenmeyen dosya, boş metin, örtüşme, geçersiz ayarlar ve birleşik Unicode karakterlerini kapsar. İlk PDF test örneğinin metin eşleşmesi sabit aralıklı font ve ayırt edici sayfa metinleriyle düzeltildi. Simülatör test başlatma sorunu sonrasında son çalışma `test-without-building` ile tamamlandı.
