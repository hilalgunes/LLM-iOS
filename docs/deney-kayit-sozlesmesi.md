# Deney kayıt sözleşmesi — v1

Android ve iOS Laboratuvar model deneyleri aynı JSON alanlarını kullanır. Bir kayıt paylaşılır; cihazda kayıtlar bir JSON dizisinde saklanır. Eski benchmark ve embedding karşılaştırma raporları kendi formatlarını korur; v1 kayıtlarıyla karıştırılmaz.

- `schemaVersion`: 1; `id`: benzersiz kayıt kimliği; `createdAtEpochMs`: Unix milisaniye; `platform`: android/ios.
- `definition`: `modelId`, `runtime`, `prompt`, `maxTokens`, `mode` (cold/warm).
- `definition.modelRevision`: doğrulanmış model sürümü bilinmiyorsa null veya eksik. Aynı model adı aynı ağırlık sürümünü garanti etmez.
- `definition.temperature`: açıkça ayarlanmışsa sayı; Android runtime varsayılanı bilinmiyorsa null. iOS mevcut üretim servisi 0.6 kullanır.
- `definition.chunkSize`, `chunkOverlap`, `topK`: model üretimi deneyinde uygulanmadığından null/eksik. Belge deneyleri için ayrılmıştır; ölçülmeyen değerler uydurulmaz.
- `metrics`: `preparationMs`, `generationMs`, `firstTokenMs`, `totalMs`. Tümü milisaniye. İlk metin gelmediyse firstTokenMs null/eksik.
- `status`: complete/failed/cancelled; `output`: tam veya kısmi yanıt; `error`: hata varsa metin.

## Ölçüm sınırları

Cold modunda uygulamanın önceki oturumu bırakılır. Bu, işletim sistemi dosya önbelleğinin temizlendiği anlamına gelmez.

Warm modunda aynı model/soru/token sınırıyla bir hazırlık yanıtı üretilir; bu yanıt ve süreleri başarılı ölçümün dışında tutulur. Ardından konuşma bağlamı sıfırlanmış ölçüm yapılır. Android warm modu yalnızca oturumu yeniden kullanılabilen LiteRT modellerinde açılır. iOS model deneyleri MLX modellerini kullanır; Apple sistem modelinin yükleme yaşam döngüsü uygulamanın kontrolünde olmadığından bu ekranda yer almaz.

Preparation, ölçüm başlangıcından oturumun hazır dönmesine kadardır; kilit bekleme ve gerekiyorsa indirme dahildir. Bazı Android motorları yüklemeyi generate içinde yapar; bu yüzden preparation saf model yükleme süresi değildir. Generation, oturum hazır olduktan üretim bitene kadardır. FirstToken, üretim başlangıcından ilk boş olmayan metin parçasına kadardır; tokenizer düzeyinde gerçek token sayımı iddiası yoktur. Kaynak bırakma ve disk kaydı bu sürelerin dışındadır.

Kayıtlı deney aynı üretim ayarlarıyla yeniden çalıştırılır. Yerel model dosyalarının değişmediği veya platformların aynı model dosyasını kullandığı garanti edilmez. Bozuk veya desteklenmeyen sürümlü geçmiş sessizce boş geçmişe çevrilmez ve üzerine yazılmaz.
