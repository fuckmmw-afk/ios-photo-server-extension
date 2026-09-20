# PhotoServer

Минимальный iOS 18+ клиент для обработки текущей фотографии через Gemini Web из Apple Photos. Репозиторий содержит приложение, Photo Editing Extension, общий Swift-код и воспроизводимую минимальную поправку к proxy, установленному в этой сессии. Старые серверные проекты не используются.

## Пользовательский сценарий

Один раз открыть приложение и проверить соединение. Далее: **Photos → фотография → Edit → ⋯ → PhotoServer → автоматическая обработка → Done → Done в Photos**, если требуется завершить общий сеанс редактирования. Process/Start отсутствуют; Retry появляется только после ошибки. Cancel — системная кнопка.

Результат возвращается через `PHContentEditingOutput`, `renderedContentURL` и `PHAdjustmentData`. Приложение не вызывает создание нового `PHAsset`. Оригинал остаётся под управлением Photos для Revert to Original. До успешного Done оригинал не изменяется. Вызов Done во время обработки ждёт её завершения; при ошибке выход не сохраняет результат.

## Совместимость: документация не равна проверке устройства

Apple документирует [Photo Editing Extensions](https://developer.apple.com/documentation/photokit/creating_photo_editing_extensions) и [запуск через Edit → More](https://support.apple.com/en-gb/102259). [Руководство iOS 27](https://support.apple.com/guide/iphone/edit-photos-and-videos-iphb08064d57/27/ios/27) ссылается на сторонние расширения. Это основание использовать `com.apple.photo-editing`, а не заменять его Share Extension.

| Версия | Статус |
|---|---|
| iOS 18 | Deployment target; физическое устройство ещё не проверено |
| iOS 26 | SDK/симулятор проверяются CI; точные версии записываются в `sdk-report.txt` |
| iOS 27 | Документация доступна; SDK и физический интерфейс не считаются проверенными без отдельного отчёта |

CI сохраняет попытку открыть extension в системном Photos и скриншоты в `.xcresult`. Если автоматизация не может пройти onboarding или обнаружить меню, тест явно помечается skipped. Это НЕ подтверждение доступности расширения. Проверка same-asset сохранения и Revert на физическом iPhone обязательна перед заявлением полной совместимости. См. `docs/verification.md`.

## Архитектура и протокол

Photos → PHContentEditingInput → исходный файл → URLSession → существующий Gemini Web proxy → PNG/JPEG → preview → PHContentEditingOutput → тот же asset.

Используется прежний `POST /openai/v1/images/generations`: к существующим `model`, `prompt`, `n: 1`, `response_format: b64_json` добавлено необязательное поле `image: data:<mime>;base64,...`. Ответ — прежний `data[0].b64_json`. Нового backend, очереди и polling нет. Загрузка в Gemini и авторизованное скачивание результата переиспользуют существующий provider. Cookies не передаются iPhone.

Модель — `gemini-3.6-flash`, фактически доступная в этой Web-сессии. Название внутреннего image-generator не подтверждено; это не обещание вызова API-модели `gemini-3.1-flash-image`. Временный промпт находится в `Shared/Settings.swift` и сохраняет содержимое, лица и композицию; продуктовый промпт будет добавлен позже. Генеративная модель не гарантирует побитовое сохранение деталей.

## Подключение

Proxy слушает только `127.0.0.1:4981` на сервере. Для iPhone он доступен по HTTPS: `https://photo.fuckmmw.space` (Cloudflare Tunnel → локальный nginx-шлюз → тот же процесс). Cookies Gemini на телефон не уходят. `localhost` на телефоне — это сам телефон, не VPS.

В приложении по умолчанию `https://photo.fuckmmw.space`. Разрешён HTTPS или HTTP на loopback. Общего ATS bypass нет. Единственная настройка — URL подключения. Sideload через Feather обычно без App Group, поэтому расширение берёт URL по умолчанию из бинарника.

## Качество и ограничения

- Используется `fullSizeImageURL`, не placeholder. Возврат `false` из `canHandleAdjustmentData` запрашивает текущую сведённую версию с уже применёнными правками.
- Входные JPEG/HEIC/HEIF/PNG отправляются исходными байтами; base64 пишется блоками в файл. Preview декодируется до 1400 px, но не используется для upload.
- При сохранении JPEG с upright-пикселями копируется; PNG или повёрнутый JPEG один раз преобразуется в JPEG качества 1.0 согласно контракту базового `renderedContentURL`. Поворот физически применяется к пикселям, orientation становится 1. Размер не уменьшается, при повороте на 90° ширина и высота меняются местами. Цветовой профиль берётся из результата; старые EXIF и геометрия оригинала не переносятся поверх нового изображения.
- Нейросеть может изменить размер, ICC/Display P3, HDR, EXIF и детализацию. Клиент не обещает восстановить утраченное. PNG alpha при JPEG-экспорте не сохраняется.
- Вход ограничен 25 MiB, тело JSON — 36 MiB; результат при рендеринге — 48 MP. При превышении ошибка, а не скрытое уменьшение. Это лимиты приложения, не универсальные лимиты Apple.
- Видео, Live Photos и RAW не поддерживаются в первой версии. iCloud-файл должен быть предоставлен Photos полностью.
- Extension выполняет сетевой запрос в foreground с timeout 360 секунд. Apple может завершить процесс раньше при нехватке ресурсов; фиксированного гарантированного memory/time бюджета нет. Фонового завершения и сохранения после закрытия extension не обещаем.
- Cancel отменяет URLSession и сохранение. Уже начавшаяся работа Google может завершиться на сервере. Автоматических повторных генераций со стороны клиента нет.
- Ошибки сети, HTTP, квоты, истёкшей cookie, отсутствия изображения и декодирования показываются пользователю с Retry.

## Идентификаторы

Единый файл `Config/Identifiers.xcconfig`: `com.example.PhotoServer`, дочерний `com.example.PhotoServer.PhotoEditingExtension`, App Group `group.com.example.PhotoServer`. Entitlements app и extension содержат одинаковую группу. Cookie/API keys в app, plist и entitlements отсутствуют. Для доступа к текущему asset расширению не нужен общий Photo Library permission.

Sideload через Feather обычно **не даёт App Groups**. Приложение и Photos-расширение тогда используют URL по умолчанию `http://localhost:4981`. Этого достаточно, если на iPhone поднят SSH-туннель на этот порт. Поле адреса в приложении проверяет связь из самого приложения; без App Group расширение его не увидит.

При внешнем подписании профилем с App Groups идентификаторы app/extension и группа должны совпадать. Инструкции по сертификатам не входят в проект.

## Сборка и тестирование

На Mac с Xcode и XcodeGen: `xcodegen generate`, затем `bash scripts/build-unsigned.sh`. Проект/схемы генерируются из `project.yml`; сформированный `.xcodeproj` также публикуется в verification artifact. `bash scripts/test-simulator.sh` запускает unit-тесты и отдельную попытку проверки Photos UI. URLProtocol fixtures не требуют Gemini и не расходуют квоту.

CI `.github/workflows/build-ios.yml` использует GitHub-hosted macOS, выбирает установленный стабильный Xcode, записывает SDKs, проверяет targets и собирает app и extension без подписания. `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=""`. Archive/exportArchive не используются.

`PhotoServer-unsigned.ipa` содержит `Payload/PhotoServer.app/PlugIns/PhotoEditingExtension.appex/`. Проверки: `unzip -l PhotoServer-unsigned.ipa`, `python3 scripts/verify-ipa.py PhotoServer-unsigned.ipa`; CI дополнительно проверяет отсутствие подписи через `codesign -d`.

Скачать: GitHub → Actions → успешный Build unsigned iOS IPA → Artifact `PhotoServer-unsigned`. При push тега `v*` workflow прикрепляет IPA к GitHub Release. IPA намеренно unsigned: его нельзя непосредственно установить на физический iPhone без внешнего подписания. Нет ad-hoc signing, `.p12`, signing secrets или embedded.mobileprovision.

Серверные изменения воспроизводятся по `server/README.md`. Ни пользовательские фото, ни cookies, ни артефакты сборки не коммитятся.
