#!/usr/bin/env python3
"""Lint the app's string catalogs (Shared/Localizable.xcstrings, whitenoise-ios/InfoPlist.xcstrings).

Shared catalog, for every key and every shipped locale:
  * a localization exists and every leaf (string unit, plural form,
    substitution form) is marked `translated` with a non-empty value;
  * format specifiers match the key as (position, type) pairs, so positional
    reordering passes and a type swap fails; a substitution shell names only
    defined substitutions, uses each one, and their argNum/formatSpecifier
    fill the key's remaining arguments; each substitution form carries that
    substitution's specifier;
  * plural variations (with `other`, and one/few/many/other for Russian) in
    the source and every locale for REQUIRED_PLURAL_KEYS and for any key that
    has them in some locale, except PLURAL_GAPS, which must be pruned once
    the gap closes;
  * REQUIRED_KEYS and ONCE_ENGLISH_KEYS exist and PINNED_VALUES match exactly;
  * no locale still shows the English copy, meaning any displayed text with
    words that English also shows, except SHARED_SPELLINGS and SHARED_FORMS,
    which must name shipped locales and be pruned once an entry no longer applies.
InfoPlist catalog: INFOPLIST_REQUIRED_KEYS exist; every key except
CFBundleDisplayName is non-empty in English and every locale; usage
descriptions are translated; INFOPLIST_PINNED_VALUES match; and
CFBundleDisplayName never carries a translated value (it would hide the build
flavor's display name).
Not checked: the source (`en`) leaves' state and specifiers, since many are
auto-extracted `new` entries that mirror the key.
"""

import argparse
import itertools
import json
import re
import sys
from pathlib import Path

LOCALES = ("de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant")
SOURCE = "en"
RUSSIAN_PLURALS = {"one", "few", "many", "other"}
# printf/NSString specifiers: optional `n$`, then a `%#@name@` substitution token,
# a conversion (flags without space, so prose like "50 % de" is not one), or `%%`.
SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?(?:#@(\w+)@|[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA])|(%))"
)

# Copy whose absence or loss of translation once shipped or would ship broken.
REQUIRED_KEYS = (
    "Settings", "Notifications", "New Chat", "Message", "Appearance", "Theme", "Light", "Dark", "System",
    "Language", "Preferences", "Draft: %@", "Edit Description", "Shared Media", "New encrypted message",
    "That QR code isn't a White Noise profile.", "Couldn't create chat", "Mark as unread", "Pin", "Pinned",
    "Unpin", "Updating chat…", "Couldn't mark as unread", "Couldn't update pin", "Push registration failed",
    "Support", "Chat with support", "Connecting to support…", "Couldn't connect to support",
    "Please check your connection and try again.", "Leave “%@”?",
    "You'll stop receiving new messages. This chat will remain on this device as read-only history until you delete it.",
    "Leaving…", "Sign Up", "Choose Avatar", "Change Avatar", "Remove Avatar", "Name", "About (Optional)",
    "Signing Up…", "Couldn’t create your account. Please try again.",
    "Couldn’t save your profile details. Please try again.", "Continue",
    "Your avatar is public. The photo is uploaded to a public service, and removing it from your profile may not "
    "delete the uploaded copy.",
    "This image is too large. Choose an image smaller than 25 MB.",
    "We couldn’t read this image. Choose another image.", "New profile", "Profile avatar preview",
    "Selected profile photo", "Camera Access Is Off", "Allow camera access in Settings to take photos and videos.",
    "Camera Is Restricted", "Camera access is restricted on this iPhone.", "Camera Unavailable",
    "The camera isn’t available on this iPhone right now.",
)

REQUIRED_PLURAL_KEYS = (
    "%lld members", "%lld person group", "%lld more messages", "%llu unread messages", "📎 %lld attachments",
    "Invited %lld members", "Published %lld updates.", "Your kind:0 metadata is live on %lld relays.",
    "You can send up to %lld photos at once",
)

# Count keys whose translations still use a single string unit rather than
# plural variations. The check fails once an entry is no longer a gap.
PLURAL_GAPS = frozenset({
    "Delete %lld selected messages?",
    "Forward %lld messages",
})

# Exact translations pinned after regressions: Sign In/Sign Up shipped as
# English copy (#895), the retention strings shipped untranslated (#1058).
PINNED_VALUES = {
    "Save profile": {
        "de": "Profil speichern", "es": "Guardar perfil", "fr": "Enregistrer le profil", "it": "Salva profilo",
        "pt": "Salvar perfil", "ru": "Сохранить профиль", "tr": "Profili kaydet", "zh-Hans": "保存个人资料",
        "zh-Hant": "儲存個人資料",
    },
    "Couldn't load chats": {
        "de": "Chats konnten nicht geladen werden", "es": "No se pudieron cargar los chats",
        "fr": "Impossible de charger les discussions", "it": "Impossibile caricare le chat",
        "pt": "Não foi possível carregar os bate-papos", "ru": "Не удалось загрузить чаты",
        "tr": "Sohbetler yüklenemedi", "zh-Hans": "无法加载聊天记录", "zh-Hant": "無法載入聊天記錄",
    },
    "Sign In": {
        "de": "Anmelden", "es": "Iniciar sesión", "fr": "Se connecter", "it": "Accedi", "pt": "Entrar",
        "ru": "Войти", "tr": "Oturum Aç", "zh-Hans": "登录", "zh-Hant": "登入",
    },
    "Sign Up": {
        "de": "Registrieren", "es": "Registrarse", "fr": "S’inscrire", "it": "Registrati", "pt": "Cadastrar-se",
        "ru": "Зарегистрироваться", "tr": "Kaydol", "zh-Hans": "注册", "zh-Hant": "註冊",
    },
    "Disappearing messages": {
        "de": "Verschwindende Nachrichten", "es": "Mensajes temporales", "fr": "Messages éphémères",
        "it": "Messaggi effimeri", "pt": "Mensagens temporárias", "ru": "Исчезающие сообщения",
        "tr": "Kaybolan mesajlar", "zh-Hans": "阅后即焚消息", "zh-Hant": "限時訊息",
    },
    "Off": {
        "de": "Aus", "es": "Desactivado", "fr": "Désactivé", "it": "Disattivato", "pt": "Desativado",
        "ru": "Выкл.", "tr": "Kapalı", "zh-Hans": "关闭", "zh-Hant": "關閉",
    },
    "Messages are kept until you delete them.": {
        "de": "Nachrichten bleiben erhalten, bis du sie löschst.",
        "es": "Los mensajes se conservan hasta que los elimines.",
        "fr": "Les messages sont conservés jusqu’à ce que vous les supprimiez.",
        "it": "I messaggi vengono conservati finché non li elimini.",
        "pt": "As mensagens são mantidas até você apagá-las.",
        "ru": "Сообщения хранятся, пока вы их не удалите.",
        "tr": "Mesajlar siz silene kadar saklanır.",
        "zh-Hans": "消息会一直保留，直到你删除它们。",
        "zh-Hant": "訊息會一直保留，直到你刪除為止。",
    },
}

# Families that once shipped with the English source marked `translated`.
RETENTION_KEYS = (
    "Disappearing messages", "Off", "Messages are kept until you delete them.",
    "Messages are deleted for everyone after the selected time.", "Custom", "Duration", "Unit",
    "Seconds", "Minutes", "Hours", "Days", "Weeks", "Enter a duration between %@ and %@.",
    "Delete older messages?", "Set Timer",
    "This timer also applies to messages already in the chat. Everything older than %@ will be deleted immediately.",
    "Updating disappearing messages…", "Disappearing messages updated", "Couldn't update disappearing messages",
)
DONATION_KEYS = (
    "You’re donating %@ each month to help people communicate freely and privately.",
    "Your monthly payment couldn’t be completed. Please check your payment method to continue your support.",
    "Your monthly donation is scheduled to end. Your support has helped us build tools for private communication.",
    "Payments stop on %@", "Donations are temporarily unavailable. Please try again later.",
    "Use up to two decimal places.", "Enter a valid USD amount.", "Thank you for your commitment",
    "By giving monthly, you help IPF keep building White Noise and tools for free, private communication.",
    "Payments", "Invoice", "Your recent payments:", "See all payments", "Invoice unavailable",
    "Your invoice is still being prepared.", "Your payment succeeded. Please try again later to view the invoice.",
    "Thank you for supporting IPF and White Noise. You’re helping people communicate freely and privately.",
    "Help the Internet Privacy Foundation (IPF), a nonprofit building tools for private communication.",
    "IPF is a 501(c)(3) nonprofit incorporated in Wyoming that builds tools to help people communicate privately. "
    "We develop White Noise and Marmot, the open messaging protocol behind it. Your donation supports this work "
    "and our belief that private conversations should be available to everyone.",
    "Charged monthly until you cancel.", "Monthly donation active", "Cancellation scheduled",
    "Monthly donation overdue", "Next payment: %@", "Thank you for your support",
    "%@ will be donated each month until you cancel.", "A donation is already in progress.",
    "About your donation", "Apple Pay isn't available for this donation.", "Apple Pay unavailable",
    "Custom donation amount in USD", "Custom amount", "Frequency", "IPF General Fund Donation",
    "Manage monthly donation", "Monthly", "Monthly donation to IPF", "One time",
    "The donation couldn't be completed. Please try again.", "The maximum donation is $5,000.",
    "The minimum donation is $1.", "USD", "Donation history access is no longer available on this device.",
    "Your donation history couldn't be loaded. Please try again.", "Recent billing activity",
    "Your monthly donation has not started yet. Check your payment method to complete it.",
    "This monthly donation has ended.",
    "This monthly donation's status is unavailable. Check Stripe to manage it.", "Ended on %@",
    "Monthly donation not yet active", "Monthly donation ended", "Monthly donation status unavailable",
    "Load more", "Paid", "Pending", "Payment failed", "Credited", "Paid outside the app",
    "See all billing activity", "This document isn't available right now. Please try again later.",
    "More billing activity couldn't be loaded. Try again.", "A new donation won't restore earlier payments.",
    "Your donation succeeded, but history couldn't be saved on this device.",
)
# These families must keep existing; the English-copy rule covers their translations.
ONCE_ENGLISH_KEYS = ("Sign In", "Sign Up") + RETENTION_KEYS + DONATION_KEYS
# Copy whose correct translation is spelled like English. Names and identifiers
# may stay English in any locale; words only in the listed locales. "Native Push"
# is the feature's name: every locale's notification footers keep it as such.
SHARED_NAMES = (
    "Claude Code", "Codex", "GIF", "GIPHY", "Hermes", "NIP-65", "Native Push", "OpenClaw", "OpenCode", "Pi",
    "QUIC · %@", "URL", "White Noise", "White Noise · %@", "https://example.com/image.jpg", "npub", "nsec1…",
)
SHARED_WORDS = {
    "%@ (IDN/punycode)": "es fr it pt ru tr", "%@ (IDN/punycode: %@)": "es it pt ru tr",
    "Hex": "de es fr it pt ru tr", "USD": "de es fr it pt ru tr", "Wi-Fi": "es fr it pt ru tr zh-Hans zh-Hant",
    "id: %@": "es it pt ru tr", "stream %@": "es it pt", "wss://relay.example.com": "de it pt ru tr zh-Hans zh-Hant",
    "%lld images": "fr", "%lld notifications": "fr", "%lld videos": "es", "%lld votes": "fr", "Admin": "de",
    "Audio": "de es fr it", "Cache": "de fr it pt", "Chats": "de es", "Contact": "fr", "Conversation": "fr",
    "Debugging": "de", "Description": "fr", "Documents": "fr", "Downloads": "de pt", "Filter": "de",
    "GIF via GIPHY": "fr pt", "GIFs": "de es pt", "Image": "fr", "Info": "de it", "Links": "de pt", "Live": "de",
    "Maintenance": "fr", "Malware": "it", "Media": "it", "Mentions": "fr", "Message": "fr", "Minutes": "fr",
    "Mode": "fr", "Moderation": "de", "Name": "de", "Notifications": "fr", "OK": "de fr it pt", "Online": "de",
    "Option %lld": "de fr", "Options": "fr", "Original": "de es pt", "Passphrase": "de it", "Photo": "fr",
    "Photos": "fr", "Provisional": "es", "Question": "fr", "Relay": "de es it pt", "Scan": "de",
    "Spam": "de es fr it pt tr", "Standard": "de fr it", "Status": "de pt", "Streaming…": "de fr it", "System": "de",
    "Tokens": "es pt", "Version": "de fr", "Version %lld": "de fr", "Video": "de es it tr", "Videos": "de es",
    "Votes": "fr", "White Noise Support": "de", "local": "es fr pt", "via GIPHY": "fr pt", "via GIPHY · %@": "fr pt",
}
# (key, locale) pairs, or (key, "*"); an entry that no longer shows English fails the check.
SHARED_SPELLINGS = frozenset(
    {(key, "*") for key in SHARED_NAMES}
    | {(key, locale) for key, locales in SHARED_WORDS.items() for locale in locales.split()}
)
# Invariable plurals: the one form a locale shares with English, so the rest stays checked.
SHARED_FORMS = {
    ("%lld videos", "it"): frozenset({"%lld video"}),
    ("%lld videos", "tr"): frozenset({"%lld video"}),
}

INFOPLIST_REQUIRED_KEYS = (
    "CFBundleName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSFaceIDUsageDescription",
    "NSLocationWhenInUseUsageDescription", "NSPhotoLibraryAddUsageDescription",
)
INFOPLIST_PINNED_VALUES = {
    "NSCameraUsageDescription": {
        "en": "White Noise uses the camera to scan profile QR codes and take photos and videos for encrypted chats.",
    },
}


def parse_format(text):
    """(sorted (position, type) arguments, substitution names) of a format string.

    Implicit specifiers are numbered from 1 in order; `%%` and `%#@name@`
    tokens consume no argument.
    """
    arguments, names, implicit = [], [], 0
    for match in SPECIFIER.finditer(text):
        position, name, length, conversion, literal = match.groups()
        if literal:
            continue
        if name is not None:
            names.append(name)
            continue
        if position is None:
            implicit += 1
            position = implicit
        arguments.append((int(position), (length or "") + conversion))
    return sorted(arguments), names


def render(arguments):
    return [f"%{position}${kind}" for position, kind in arguments]


def plural_forms(localization):
    """Every plural-variation dict of one localization, direct or via substitutions."""
    plurals = []
    variations = localization.get("variations")
    if variations is not None:
        plurals.append(variations.get("plural"))
    for substitution in localization.get("substitutions", {}).values():
        plurals.append(substitution.get("variations", {}).get("plural"))
    return plurals


def has_plurals(localization):
    return any(isinstance(plural, dict) for plural in plural_forms(localization))


def unit_errors(where, key, unit):
    errors = []
    if unit.get("state") != "translated":
        errors.append(f"{where}: {key!r} is not translated (state: {unit.get('state')})")
    value = unit.get("value")
    if value is None:
        errors.append(f"{where}: {key!r} has a string unit without a value")
    elif key and not value.strip():
        errors.append(f"{where}: empty value for {key!r}")
    return errors, value


def plural_dict_errors(where, key, plural, expected):
    """Leaves of one plural dict; `expected` is the specifier list each form must carry."""
    errors = []
    if not isinstance(plural, dict):
        return [f"{where}: {key!r} has variations without a plural dict"]
    for category, form in sorted(plural.items()):
        found, value = unit_errors(f"{where} [{category}]", key, form.get("stringUnit", {}))
        errors += found
        if value is not None and expected(value) is not None:
            errors.append(f"{where} [{category}]: {expected(value)} for {key!r}")
    return errors


def localization_errors(locale, key, localization, key_arguments):
    errors = []
    substitutions = localization.get("substitutions", {})
    unit = localization.get("stringUnit")
    if unit is None and "variations" not in localization:
        return [f"{locale}: no value for {key!r}"] if key else []

    if unit is not None:
        found, value = unit_errors(locale, key, unit)
        errors += found
        if value is not None:
            arguments, names = parse_format(value)
            if substitutions or names:
                for name in sorted(set(names) - set(substitutions)):
                    errors.append(f"{locale}: {key!r} uses %#@{name}@ without a substitution")
                for name in sorted(set(substitutions) - set(names)):
                    errors.append(f"{locale}: {key!r} defines substitution {name!r} its value never uses")
                for name, substitution in substitutions.items():
                    arg, spec = substitution.get("argNum"), substitution.get("formatSpecifier")
                    if not isinstance(arg, int) or not spec:
                        errors.append(f"{locale}: substitution {name!r} of {key!r} needs argNum and formatSpecifier")
                    else:
                        arguments.append((arg, spec))
                arguments.sort()
            if arguments != key_arguments:
                errors.append(f"{locale}: specifiers {render(arguments)} for {key!r} expect {render(key_arguments)}")

    variations = localization.get("variations")
    if variations is not None:
        def direct(value):
            arguments, names = parse_format(value)
            if names or arguments != key_arguments:
                return f"specifiers {render(arguments)} expect {render(key_arguments)}"
            return None
        errors += plural_dict_errors(locale, key, variations.get("plural"), direct)

    for name, substitution in sorted(substitutions.items()):
        spec = substitution.get("formatSpecifier")

        def carried(value, spec=spec):
            kinds = [kind for _, kind in parse_format(value)[0]]
            if kinds != [spec]:
                return f"substitution {name!r} form carries {kinds}, expects ['{spec}']"
            return None
        errors += plural_dict_errors(f"{locale} {name}", key, substitution.get("variations", {}).get("plural"), carried)
    return errors


def plural_requirement_errors(key, localizations, locales, require=True):
    """Each plural dictionary (direct or per substitution) must be complete on
    its own; a union across substitutions would hide a form missing `other`.
    `require=False` (a PLURAL_GAPS key) skips locales without any plural
    dictionary but still checks the ones that exist."""
    errors = []
    for locale in locales:
        forms = [p for p in plural_forms(localizations.get(locale, {})) if isinstance(p, dict)]
        if not forms:
            if require:
                errors.append(f"{locale}: {key!r} needs plural variations")
        elif any("other" not in form for form in forms):
            errors.append(f"{locale}: {key!r} is missing an `other` plural form")
        elif locale == "ru" and any(not RUSSIAN_PLURALS <= set(form) for form in forms):
            errors.append(f"ru: {key!r} needs one/few/many/other plural forms")
    return errors


SUBSTITUTION_TOKEN = re.compile(r"%(?:\d+\$)?#@(\w+)@")


def displayed(localization):
    """The texts one localization can show: each plural form, or its shell with
    every combination of its substitutions' forms filled in, `%2$@` read as `%@`."""
    value = localization.get("stringUnit", {}).get("value")
    plural = localization.get("variations", {}).get("plural")
    if isinstance(plural, dict):
        texts = {form.get("stringUnit", {}).get("value", "") for form in plural.values()}
    elif value is None:
        texts = set()
    else:
        substitutions = localization.get("substitutions", {})
        choices = [
            [form.get("stringUnit", {}).get("value", "")
             for form in (substitutions.get(name, {}).get("variations", {}).get("plural") or {}).values()]
            or [f"%#@{name}@"]
            for name in SUBSTITUTION_TOKEN.findall(value)
        ]
        texts = set()
        for combination in itertools.product(*choices):
            filled = iter(combination)
            texts.add(SUBSTITUTION_TOKEN.sub(lambda _: next(filled), value))
    return {re.sub(r"%\d+\$", "%", text) for text in texts}


def has_words(value):
    return re.search(r"[^\W\d_]", SPECIFIER.sub("", value)) is not None


def forms_by_argument(localization):
    """{argNum: plural forms} of one localization's substitutions, `%2$@` read as `%@`."""
    return {
        substitution.get("argNum"): {re.sub(r"%\d+\$", "%", form.get("stringUnit", {}).get("value", ""))
                                     for form in (substitution.get("variations", {}).get("plural") or {}).values()}
        for substitution in localization.get("substitutions", {}).values()
    }


def english_shown(key, localizations, locale):
    """The texts with words that `locale` can show and English shows too, so a
    plural left half in English still fails. Displayed text is compared, so
    plural layout, substitution names and placeholder numbering don't matter;
    so is each substitution's forms against English's for the same argument,
    which catches English counts inside a translated sentence. The key's own
    text counts as English too (older wording, or an identifier shown raw); a
    count key needs English plurals for its singular to count. Matching is
    exact, so English words inside a translated sentence pass. Format-only
    text ("%@ · %@", "%lld") says nothing either way.
    """
    source, target = localizations.get(SOURCE, {}), localizations.get(locale, {})
    english = displayed(source) | displayed({"stringUnit": {"value": key}})
    english_forms = forms_by_argument(source)
    shown = {text for text in displayed(target) if has_words(text) and text in english}
    return shown | {form for argument, forms in forms_by_argument(target).items() for form in forms
                    if has_words(form) and form in english_forms.get(argument, ())}


def check_strings_catalog(catalog, locales=LOCALES):
    errors = []
    strings = catalog.get("strings", {})
    for key in dict.fromkeys(REQUIRED_KEYS + REQUIRED_PLURAL_KEYS + ONCE_ENGLISH_KEYS):
        if key not in strings:
            errors.append(f"missing required key {key!r}")

    for key, entry in sorted(strings.items()):
        localizations = entry.get("localizations", {})
        key_arguments = parse_format(key)[0]
        for locale in locales:
            localization = localizations.get(locale)
            if localization is None:
                errors.append(f"{locale}: missing localization for {key!r}")
                continue
            errors += localization_errors(locale, key, localization, key_arguments)
            shared = (key, locale) in SHARED_SPELLINGS or (key, "*") in SHARED_SPELLINGS
            if not shared and english_shown(key, localizations, locale) - SHARED_FORMS.get((key, locale), set()):
                errors.append(f"{locale}: {key!r} still shows the English copy")

        inferred = any(has_plurals(loc) for loc in localizations.values())
        if key in REQUIRED_PLURAL_KEYS:
            errors += plural_requirement_errors(key, localizations, (SOURCE, *locales))
        elif inferred:
            scope = (SOURCE, *locales) if SOURCE in localizations else locales
            errors += plural_requirement_errors(key, localizations, scope, require=key not in PLURAL_GAPS)

    for key in sorted(PLURAL_GAPS):
        localizations = strings.get(key, {}).get("localizations")
        if localizations is None:
            errors.append(f"remove {key!r} from PLURAL_GAPS: the key no longer exists")
        elif not plural_requirement_errors(key, localizations, (SOURCE, *locales)):
            errors.append(f"remove {key!r} from PLURAL_GAPS: it has plural variations in every locale")

    for key, values in sorted(PINNED_VALUES.items()):
        localizations = strings.get(key, {}).get("localizations", {})
        for locale, expected in sorted(values.items()):
            if locale not in locales and locale != SOURCE:
                continue
            actual = localizations.get(locale, {}).get("stringUnit", {}).get("value")
            if actual != expected:
                errors.append(f"{locale}: {key!r} is {actual!r}, pinned {expected!r}")

    for key, locale in sorted(SHARED_SPELLINGS):
        if locale != "*" and locale not in LOCALES:
            errors.append(f"({key!r}, {locale!r}) in SHARED_SPELLINGS names a locale that does not ship")
            continue
        scope = locales if locale == "*" else tuple(set(locales) & {locale})
        if not scope:
            continue
        localizations = strings.get(key, {}).get("localizations")
        if localizations is None or not any(english_shown(key, localizations, each) for each in scope):
            errors.append(f"remove ({key!r}, {locale!r}) from SHARED_SPELLINGS: no locale shows it as English")

    for (key, locale), forms in sorted(SHARED_FORMS.items()):
        if locale not in LOCALES:
            errors.append(f"({key!r}, {locale!r}) in SHARED_FORMS names a locale that does not ship")
        elif locale in locales:
            localizations = strings.get(key, {}).get("localizations", {})
            for form in sorted(forms - english_shown(key, localizations, locale)):
                errors.append(f"remove {form!r} from SHARED_FORMS[({key!r}, {locale!r})]: {locale} no longer shows it")
    return errors


def check_infoplist_catalog(catalog, locales=LOCALES):
    errors = []
    strings = catalog.get("strings", {})
    for key in INFOPLIST_REQUIRED_KEYS:
        if key not in strings:
            errors.append(f"missing required InfoPlist key {key}")
    for key, entry in sorted(strings.items()):
        localizations = entry.get("localizations", {})
        if key == "CFBundleDisplayName":
            for locale, localization in sorted(localizations.items()):
                if localization.get("stringUnit", {}).get("state") == "translated":
                    errors.append(f"{locale}: CFBundleDisplayName must not be translated; "
                                  "it would hide the flavor display name")
            continue
        for locale in (SOURCE, *locales):
            unit = localizations.get(locale, {}).get("stringUnit", {})
            if not (unit.get("value") or "").strip():
                errors.append(f"{locale}: empty InfoPlist value for {key}")
            elif key.endswith("UsageDescription") and locale != SOURCE and unit.get("state") != "translated":
                errors.append(f"{locale}: {key} is not translated (state: {unit.get('state')})")
    for key, values in sorted(INFOPLIST_PINNED_VALUES.items()):
        localizations = strings.get(key, {}).get("localizations", {})
        for locale, expected in sorted(values.items()):
            actual = localizations.get(locale, {}).get("stringUnit", {}).get("value")
            if actual != expected:
                errors.append(f"{locale}: {key} is {actual!r}, pinned {expected!r}")
    return errors


def check_repo(root):
    shared = json.loads((root / "Shared/Localizable.xcstrings").read_text(encoding="utf-8"))
    infoplist = json.loads((root / "whitenoise-ios/InfoPlist.xcstrings").read_text(encoding="utf-8"))
    return (
        [f"Localizable: {error}" for error in check_strings_catalog(shared)]
        + [f"InfoPlist: {error}" for error in check_infoplist_catalog(infoplist)]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root (default: this script's repository)")
    args = parser.parse_args()
    errors = check_repo(args.root)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"{len(errors)} localization catalog problem(s)", file=sys.stderr)
        return 1
    if PLURAL_GAPS:
        print(f"note: {len(PLURAL_GAPS)} count key(s) still lack translated plural variations: "
              + ", ".join(sorted(PLURAL_GAPS)))
    print("Localization catalogs OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
