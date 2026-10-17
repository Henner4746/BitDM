import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

// ---- identity / mock constants ----
const myId = 'B3XK-7QMD-2FTV-9SLN-4HRW-6JYC-8PZB-5NKQ';
const c1 = 'K7QP-2M9X-4TVB-8HRS-J3NC-5WDY-6ZFM-Q2LX';
const c2 = 'T4RB-9NKM-3JWD-7XLP-2QCV-8HFY-5ZTB-8VQD';
const c3 = 'Z9HC-4LPM-8XKV-2WRT-6NDB-3JQY-7FSZ-M4KP';

String shortId(String id) =>
    '${id.substring(0, 4)}…${id.substring(id.length - 4)}';

// ---- Nocturne palette ----
class Pal {
  final Color shell, bg, surf, surf2, navbg, ink, muted, dim, line, lineSoft,
      accent, accLight, wash, tint, tintLine, tintInk, scrim, onAcc, accHover;
  const Pal({
    required this.shell,
    required this.bg,
    required this.surf,
    required this.surf2,
    required this.navbg,
    required this.ink,
    required this.muted,
    required this.dim,
    required this.line,
    required this.lineSoft,
    required this.accent,
    required this.accLight,
    required this.wash,
    required this.tint,
    required this.tintLine,
    required this.tintInk,
    required this.scrim,
    required this.onAcc,
    required this.accHover,
  });

  /// Zwischen zwei Paletten ueberblenden — fuer den langsamen Themenwechsel.
  static Pal lerp(Pal a, Pal b, double t) {
    Color l(Color x, Color y) => Color.lerp(x, y, t)!;
    return Pal(
      shell: l(a.shell, b.shell),
      bg: l(a.bg, b.bg),
      surf: l(a.surf, b.surf),
      surf2: l(a.surf2, b.surf2),
      navbg: l(a.navbg, b.navbg),
      ink: l(a.ink, b.ink),
      muted: l(a.muted, b.muted),
      dim: l(a.dim, b.dim),
      line: l(a.line, b.line),
      lineSoft: l(a.lineSoft, b.lineSoft),
      accent: l(a.accent, b.accent),
      accLight: l(a.accLight, b.accLight),
      wash: l(a.wash, b.wash),
      tint: l(a.tint, b.tint),
      tintLine: l(a.tintLine, b.tintLine),
      tintInk: l(a.tintInk, b.tintInk),
      scrim: l(a.scrim, b.scrim),
      onAcc: l(a.onAcc, b.onAcc),
      accHover: l(a.accHover, b.accHover),
    );
  }
}

const palDark = Pal(
  shell: Color(0xFF0B0C12),
  bg: Color(0xFF161826),
  surf: Color(0xFF232532),
  surf2: Color(0xFF1C1E2C),
  navbg: Color(0xFF1B1D2B),
  ink: Color(0xFFE9E9ED),
  muted: Color(0xFF9397AB),
  dim: Color(0xFF75798C),
  line: Color(0xFF3F424D),
  lineSoft: Color(0x24E9E9ED),
  accent: Color(0xFF9184D9),
  accLight: Color(0xFFB5ABFC),
  wash: Color(0x249184D9),
  tint: Color(0xFF2B2741),
  tintLine: Color(0xFF423A6A),
  tintInk: Color(0xFFD2CEFD),
  scrim: Color(0xA80B0C12),
  onAcc: Color(0xFF161826),
  accHover: Color(0xFFB5ABFC),
);

const palLight = Pal(
  shell: Color(0xFFCFD3E5),
  bg: Color(0xFFF3F5FE),
  surf: Color(0xFFE4E7F5),
  surf2: Color(0xFFECEFFB),
  navbg: Color(0xFFE9ECF8),
  ink: Color(0xFF292B31),
  muted: Color(0xFF595D6C),
  dim: Color(0xFF75798C),
  line: Color(0xFFCFD3E5),
  lineSoft: Color(0x24292B31),
  accent: Color(0xFF5D5294),
  accLight: Color(0xFF423A6A),
  wash: Color(0x1F5D5294),
  tint: Color(0xFFE7E5FE),
  tintLine: Color(0xFFB5ABFC),
  tintInk: Color(0xFF423A6A),
  scrim: Color(0x66292B31),
  onAcc: Color(0xFFF3F5FE),
  accHover: Color(0xFF423A6A),
);

const avPalDark = [
  Color(0xFF9184D9), Color(0xFF5D5294), Color(0xFF3F424D),
  Color(0xFFB5ABFC), Color(0xFF292B31), Color(0xFF796CBF),
];
const avPalLight = [
  Color(0xFF5D5294), Color(0xFFB5ABFC), Color(0xFFCFD3E5),
  Color(0xFF9184D9), Color(0xFFE7E5FE), Color(0xFF796CBF),
];

// ---- i18n ----
const Map<String, List<String>> jumpLabels = {
  'en': ['Onboarding', 'Secure device', 'My ID', 'Add', 'Chat list', 'Chat', 'Settings'],
  'de': ['Onboarding', 'Gerät absichern', 'Meine ID', 'Adden', 'Chatliste', 'Chat', 'Einstellungen'],
};

const Map<String, Map<String, String>> strings = {
  'en': {
    'h1a': 'No name.', 'h1b': 'No number.',
    'intro': 'BitDM creates an identity on this device. You get one long ID — that is all anyone needs to add you.',
    'b1': 'No phone number, no email', 'b2': 'Keys never leave the device', 'b3': 'No account, no recovery',
    'create': 'Create identity', 'actCreate': 'Create', 'actSave': 'Save', 'createNote': 'Takes under a second. Works offline.',
    'restoreLink': 'I already have 12 words',
    'restoreLinkSub': 'Lost or replaced your phone? Bring your identity back here.',
    'restoreTitle': 'Restore identity',
    'restoreIntro': 'Enter the 12 words in the order you wrote them down. Order matters — the same words in a different order are a different identity.\n\nOld messages do not come along. This device starts with an empty conversation list and sees everything new from now on.\n\nIf another device already uses these words, it stays signed in and keeps receiving every new message — a device cannot be logged out. If your old phone was stolen without the app lock on, a new identity is safer.',
    'restoreHint': 'word1 word2 word3 …',
    'restoreDo': 'Restore',
    'restoreCount': 'That is {n} words, it needs {soll}.',
    'restoreUnknownWord': 'One word is not in the list — it is marked above. Most likely a typo.',
    'restoreChecksum': 'Every word is valid on its own, but together they do not add up. Usually two words swapped, or one is a different word from the same list. Check the order.',
    'restoreNote': 'What comes back: your identity and your address — people can reach you again. What does NOT come back: your messages and contacts. They lived only on the old phone, encrypted, and no server ever had a copy. That is not a shortcoming; it is why nobody else could read them either.',
    'wiped': 'All data was deleted. The old identity cannot be recovered.',
    'creating': 'Creating identity',
    'phraseTitle': 'Your 12 words',
    'phraseSub': 'This is the only way back if this phone is lost, broken or wiped. There is no server that could restore it for you.',
    'phraseWarn': 'Write them down on paper, in this order. Anyone who has them IS you. Never photograph them, never type them into a website.',
    'phraseDone': 'I wrote them down',
    'noChats': 'No conversations yet. Share your ID so someone can add you.\n\nIf you entered your 12 words here: old messages stay on the other device. Everything new shows up on both.',
    'badAddress': 'That is not a valid BitDM ID. Check for typos — the ID carries a checksum.',
    'tooLong': 'That message is too long. BitDM carries up to 4096 characters at a time — split it into two.',
    'safetyNumber': 'Safety number',
    'verifyNoSession': 'Available once you have exchanged a message. The number is derived from both keys.',

    'scanHint': 'Point the camera at the QR code of the other person. Nothing is stored, nothing is sent - the picture is only read on this device.',
    'scanNoCamera': 'No camera available. Without camera access the code cannot be read - you can paste the address instead.',
    'waitingForAccept': 'Request sent — waiting for confirmation',
    'locked': 'Locked',
    'lockedSub': 'The identity on this phone is sealed. It opens only with a factor you set up — the key itself is nowhere on this device in readable form, not with root, not with the file in hand.',
    'unlock': 'Unlock',
    'unlockStick': 'Use security key',
    'lockedNoFactor': 'No usable factor found for this identity. The slot file may be damaged. Your 12 words still restore the identity on another device — the messages on this phone are lost.',
    'stickIntro': 'The key holds a secret that cannot be copied off it. Setting up needs TWO touches: one to create the credential, one to fetch the secret. That is not a glitch — there is no other way.',
    'stickUsb': 'Plug in',
    'stickNfc': 'Tap',
    'stickPinLabel': 'Key PIN',
    'stickPinHint': 'The PIN of the security key, not of this phone. It never leaves the phone in the clear. Leave empty if the key has none.',
    'stickWorking': 'Touch the key when it blinks — twice.',
    'stickPinWrong': 'Wrong PIN.',
    'stickPinWrongLeft': 'Wrong PIN. {n} attempts left before the key locks itself for good.',
    'stickPinNeeded': 'This key has a PIN. Enter it above.',
    'stickLostNote': 'If the key is lost, this slot cannot be opened. Keep a second factor. Your 12 words still restore the identity on another device.',
    'lockNoScreenLock': 'No screen lock set',
    'lockNoScreenLockBody': 'This phone has no lock screen, so there is nothing to bind the key to. Set up a fingerprint or a PIN in the Android settings first — a lock that anyone can open would not be one.',
    'notifOne': 'New message',
    'notifMany': '{n} new messages',
    'fidoProbe': 'Test security key',
    'fidoHold': 'Hold your security key against the back of the phone. Only one command is sent: a question about what the key can do. Nothing is created, nothing is changed, no PIN is asked for.',
    'fidoNoNfc': 'NFC is off or not available. Turn it on in the Android settings.',
    'myId': 'My ID', 'myIdSub': 'Share it so someone can add you.', 'share': 'Share', 'copy': 'Copy', 'copied': 'Copied',
    'myIdEmpty': 'No identity yet. Create one on the start screen, or restore an existing one from your 12 words — then your ID appears here.',
    'idNote': 'The ID holds no private key. Details under Settings › Security.',
    'geraeteEins': 'One device uses this identity.',
    'geraeteViele': '{n} devices use this identity — anyone with your 12 words gets their own copy of every message. There is no way to log a device out.',
    // Geraeteliste (docs/GERAETEABMELDUNG.md). Der Satz oben gilt nur noch
    // bei einem Relay ohne Geraeteliste.
    'geraeteVieleListe': '{n} devices use this identity. Each one had to be confirmed on a device you already had — you can sign any of them out.',
    'geraeteVerwalten': 'Manage devices',
    'geraeteTitel': 'Devices',
    'geraeteDieses': 'this device',
    'geraeteSeit': 'since {d}',
    'geraeteOhneName': 'Device {n}',
    'geraeteAbmelden': 'Sign out',
    'geraeteAbmeldenFrage': 'Sign out {name}? It stops receiving messages right away and forgets your 12 words. Its chats stay encrypted on it; only your 12 words open them again.',
    'geraeteDiesesAbmelden': 'Sign out this device',
    'geraeteDiesesAbmeldenFrage': 'Sign out this device? It forgets your 12 words and stops receiving messages. Your other devices keep working.',
    'geraeteAlleAnderen': 'Sign out all other devices',
    'geraeteAlleAnderenFrage': 'Sign out every device except this one?',
    'geraeteHinzufuegen': 'Add device',
    'geraeteCodeTitel': 'Code for the new device',
    'geraeteCodeText': 'On the new device, enter your 12 words and then this code. It works once and for 10 minutes. Nobody else sees it — not even the server.',
    'geraeteCodeWartet': 'Waiting for the new device …',
    'geraeteHinzugefuegt': 'Device added.',
    'geraeteVoll': 'This identity already has 5 devices. Sign one out first.',
    'geraeteKeineListe': 'This server does not know device lists yet. Signing out a device only works after it is updated.',
    'geraeteFehler': 'That did not work. Check the connection and try again.',
    'geraeteWoerterHinweis': 'Anyone who knows your 12 words can sign out all your devices and take over. If that has happened — say the phone was stolen unlocked, or the words were lying around — only a new identity helps.',
    'beitrittTitel': 'This device is not confirmed yet',
    'beitrittText': 'Your identity is already in use on another device. There, open Settings › My ID › Manage devices › Add device, and enter the code here.',
    'beitrittCode': 'Code from the other device',
    'beitrittSenden': 'Confirm',
    'beitrittWartet': 'Waiting for the other device …',
    'beitrittAbbrechen': 'Cancel',
    'beitrittCodeFalsch': 'That is not a valid code (16 characters).',
    'beitrittKeinGeraet': 'No other device any more?',
    'beitrittZuruecksetzen': 'Sign out all other devices',
    'beitrittZuruecksetzenFrage': 'All other devices of this identity are signed out and receive nothing from now on. Do this if your phone is gone. Anyone who knows your 12 words can do the same — if the phone was unlocked or the words are not safe, create a new identity afterwards.',
    'abgemeldetHinweis': 'This device was signed out{von}. Your chats stay here, encrypted; your 12 words bring them back — another device then has to confirm it.',
    'abgemeldetVon': ' by {name}',
    'connBeitritt': 'Device not confirmed',
    'shareFailed': 'No app to share with was found.',
    'addTitle': 'Add contact', 'idLabel': 'BitDM ID', 'paste': 'Paste', 'scan': 'Scan QR', 'sendReq': 'Send request',
    'pending': 'Pending', 'reqSentNote': 'Request sent. The chat opens once the other side confirms.',
    'peerNeedsUpdate': 'The other side has to update BitDM (2.0 or newer). Until then your messages wait here and go out on their own afterwards.',

    'addFoot': 'No messages are transmitted before confirmation. A contact can be removed unilaterally at any time.',
    'chats': 'Chats', 'connOnline': 'connected', 'connConnecting': 'connecting', 'connOffline': 'offline', 'connError': 'no connection', 'connGeraeteVoll': 'too many devices', 'wantsChat': 'Wants to start an encrypted chat with you.', 'accept': 'Accept', 'decline': 'Decline',
    'noNames': 'Contacts appear as an ID and a pattern. There are no names — not even local ones.',
    'encDetails': 'Encrypted · Details', 'message': 'Message', 'send': 'Send',
    'encryption': 'Encryption', 'protocol': 'Protocol', 'sessionKey': 'Session key', 'selfDestruct': 'Self-destructing messages',
    'selfDestructSub': 'Optional, per device', 'readReceipts': 'Read receipts', 'readReceiptsSub': 'Default: on',
    'verifyNote': 'Compare the session key in person to verify the other side.', 'close': 'Close',
    'secureTitle': 'Secure this device', 'secureSub': 'Your identity exists only here. Add at least one way to prove it is you before the app unlocks.',
    'secureFoot': 'You can add or remove factors later under Settings › Access.', 'secureSkip': 'Skip for now', 'secureDone': 'Continue',
    'access': 'Access', 'on2': 'Active', 'offMethod': 'Not set up', 'add': 'Set up', 'remove': 'Remove',
    'bio': 'Biometrics', 'bioSub': 'Fingerprint or face unlock on this device',

    'devpin': 'Device lock', 'devpinSub': 'The PIN, pattern or password of this phone',
    'pw': 'App password', 'pwSub': 'A password only for BitDM — stays in your head',
    'enrollPw': 'Set an app password',
    'pwIntro': 'This slot hangs on NOTHING but the password. No secure area, no key. Anyone who copies the slot file can try on their own hardware for as long as they like — Argon2id makes every attempt expensive, but it cannot make a short password long.',
    'pwHint': 'Password',
    'pwAgain': 'Again',
    'pwMismatch': 'The two entries differ.',
    'pwWeak': 'Too short. That gives roughly {ist} bits, and at least {soll} are needed. Four or five random words are easier to remember than a short cryptic one — and far stronger.',
    'pwLostNote': 'Forgotten means gone. There is no reset. Your 12 words still restore the identity on another device.',
    'pwUnlockHint': 'Your BitDM app password. Not the phone PIN, not the security key PIN.',
    'unlockBio': 'Fingerprint',
    'unlockDevPin': 'Device lock',
    'unlockPw': 'App password',
    'unlockFailed': 'That did not open the slot.',
    'receiving': 'Receiving',
    'bgReceive': 'Receive in the background',
    'bgReceiveSub': 'Whether messages arrive while the app is closed',
    'bgOff': 'Off', 'bgLive': 'Live', 'bg15': '15 min', 'bg60': '1 h', 'bg240': '4 h', 'bgPush': 'Push',
    'bgOffNote': 'Messages arrive when you open the app. Nothing runs in the background, nothing costs battery, no permanent notification. Fine if you check BitDM anyway — nothing is lost, the relay holds messages for 14 days.',
    'bgPushNote': 'Only worth it if you ALREADY use a push app for other apps (Element, Tusky, FluffyChat). Then BitDM comes along for free — the connection is there anyway. Installing ntfy just for BitDM buys you little: one app holds a connection instead of another. NOT Google either way: the nudge goes through push.bitdm.net, the same operator as the relay.',
    'bgLiveNote': 'Constantly connected — messages arrive the moment they are sent. Costs the most battery, but far less than it sounds: an idle connection is a few packets an hour. Pick this if BitDM is how people actually reach you.',
    'bg15Note': 'Connects briefly every 15 minutes. Feels almost live, uses noticeably less battery than a constant connection, and needs no second app. The sensible default — pick this unless you have a reason not to.',
    'bg60Note': 'Once an hour. Enough if nobody is waiting for an instant reply. Barely measurable on the battery.',
    'bg240Note': 'Four times a day. For anyone who treats BitDM like a mailbox rather than a chat.',
    'bgConflict': 'This does not work right now: the relay only answers with a signature from your identity key, and that key sits behind the app lock. With "Lock again after: Instantly" the app has no key the moment you put it down. Set the lock delay to 5 minutes or Never — or accept that messages arrive when you open the app.',
    'bgNotifTitle': 'BitDM',
    'bgNotifText': 'Ready to receive',
    'pushGuideTitle': 'Set up push',
    'pushGuideIntro': 'Push needs a small helper app on your phone that holds one connection for all apps that use it. BitDM uses ntfy. Four steps, two minutes.',
    'pushGuideLink': 'Show setup guide again',
    'pushStep1': 'Install ntfy',
    'pushStep1Sub': 'Free and open source. Either store works — F-Droid if you avoid Google.',
    'pushStep2': 'Enter the server in ntfy',
    'pushStep2Sub': 'Open ntfy → Settings → General → "Default server". Delete what is there and enter this address:',
    'pushStep3': 'Check that UnifiedPush is on',
    'pushStep3Sub': 'In ntfy: Settings → Advanced → "Enable UnifiedPush". Normally already on — just make sure.',
    'pushStep4': 'Come back and pick Push',
    'pushStep4Sub': 'Here under Receiving. DO NOT press the + button in ntfy — that is for topics you add by hand. BitDM registers itself; a subscription starting with "up" then appears in ntfy on its own. Leave it alone.',
    'pushOrderWarning': 'The order matters. ntfy builds the push address from the server that is set AT THE MOMENT OF REGISTERING. Pick Push first and you get an address on ntfy.sh — BitDM rejects it, because the relay only accepts its own push server.',
    'pushOpenNtfy': 'Open ntfy',
    'pushNoNtfy': 'ntfy is not installed yet — step 1.',
    'pushFailed': 'The push app refused. Open ntfy once and try again.',
    'lockDelay': 'Lock again after',
    'lockDelaySub': 'How long the app may stay open in the background',
    'delayNow': 'Instantly', 'delay1m': '1 min', 'delay5m': '5 min', 'delayNever': 'Never',
    'hw': 'Hardware security key', 'hwSub': 'FIDO2 key over USB-C or NFC',

    'enrollHw': 'Insert or tap your key',

 'waiting': 'Waiting for device',
    'minOne': 'At least one factor stays required.',
    'settings': 'Settings', 'general': 'General', 'security': 'Security', 'identity': 'Identity', 'emergency': 'Emergency',
    'language': 'Language', 'languageSub': 'App-wide', 'appearance': 'Appearance', 'appearanceSub': 'Dark by default',
    'screenshot': 'Screenshot protection', 'screenshotSub': 'Warning in chat, preview blocked',
    'myIdQr': 'My ID & QR',
    'panic': 'Panic mode', 'panicSub': 'Delete identity, contacts and messages instantly and irreversibly.',
    'panicTitle': 'Delete everything?', 'panicBody': 'This identity, all contacts and all messages will be removed from this device. There is no recovery.',
    'cancel': 'Cancel', 'delete': 'Delete',
    'dark': 'Dark', 'light': 'Light', 'off': 'Off', 'h1': '1 hour', 'h24': '24 hours', 'd7': '7 days', 'on': 'On',
    'navChats': 'Chats', 'navId': 'My ID', 'navSet': 'Settings',
    'voice': 'Voice message', 'newContact': 'New contact',
    'reply': 'Reply', 'copyMsg': 'Copy', 'edit': 'Edit', 'deleteAll': 'Delete for everyone', 'deleteMe': 'Delete for me',
    'edited': 'edited', 'deletedMsg': 'This message was deleted', 'deletedMine': 'You deleted this message',
    'replyTo': 'Reply to', 'editing': 'Editing', 'replyGone': 'Original message not available', 'attachment': 'Attachment',
    'notPossible': 'That is no longer possible for this message.', 'deleteAllAsk': 'Delete for everyone?',
    'deleteAllBody': 'The message disappears on both sides. Anyone who saved it before still has it.',
    'pin': 'Pin', 'unpin': 'Unpin', 'archive': 'Archive', 'unarchive': 'Unarchive', 'mute': 'Mute', 'unmute': 'Unmute',
    'chatFristStd': 'Default', 'typing': 'typing…', 'notes': 'Note to self',
    'groupCreate': 'New group', 'groupName': 'Group name', 'groupMembers': 'members', 'groupAdmin': 'ADMIN',
    'groupYou': 'You', 'groupAdd': 'Add members', 'groupRemove': 'Remove from group', 'groupRename': 'Rename',
    'groupLeave': 'Leave group', 'groupNew': 'New group', 'groupLeft': 'You left this group',
    'groupNotMember': 'You are no longer a member of this group.',
    'groupNoContacts': 'No contacts to add yet.',
    'groupInvalid': 'A group needs a name and 1 to 19 other members.',
    'voiceSend': 'Send voice message', 'voiceDiscard': 'Discard recording', 'voicePlay': 'Play',
    'micDenied': 'BitDM needs the microphone for voice messages.',
    'micDeniedForever': 'The microphone is blocked. Allow it in the system settings for voice messages.',
    'micFailed': 'Recording could not start.',
    'backup': 'Backup', 'backupSub': 'Contacts and history as an encrypted file. It only opens with your 12 words. Attachments themselves are not included, and neither are keys.',
    'backupCreate': 'Create', 'backupRestore': 'Restore', 'backupSaved': 'Saved:', 'backupRestored': 'Messages added:',
    'backupWrong': 'This backup belongs to a different identity or is damaged.',
    'poll': 'Poll', 'pollNew': 'New poll', 'pollQuestion': 'Question', 'pollOption': 'Option',
    'pollMulti': 'Multiple answers allowed', 'pollSingle': 'One answer', 'pollInvalid': 'A poll needs a question and 2 to 10 answers.',
    'scheduleTitle': 'Send later', 'scheduledFor': 'scheduled', 'schedulePast': 'That time has already passed.',
    'pinMsg': 'Pin message', 'unpinMsg': 'Unpin message', 'pinnedTitle': 'Pinned messages',
    'pinnedTag': 'Pinned', 'mutedTag': 'Muted',
    'keyArt': 'Key picture', 'keyArtSelf': 'Drawn from your address. Your contacts see the same picture for your key.', 'keyArtPeer': 'Drawn from this contact\'s key. Their own settings show the same picture — a quick check, the safety number is the proof.',
    'cmd_timer': 'Disappearing messages here: 1h · 24h · 7d · off · std', 'cmd_verify': 'Show the safety number', 'cmd_poll': 'Create a poll', 'cmd_shrug': 'Append a shrug', 'cmdTimerBad': 'Try /timer 1h, 24h, 7d, off or std', 'cmdThemeBad': 'No theme by that name', 'cmdVerifyNone': 'Only a one-to-one chat has a safety number',
    'star': 'Star', 'unstar': 'Remove star', 'starEmpty': 'No starred messages yet. Long-press a message and choose Star — it stays on this device only.', 'filterAll': 'All', 'filterUnread': 'Unread', 'filterGroups': 'Groups', 'filterStarred': 'Starred',
    'quietHours': 'Quiet hours', 'quietHoursSub': 'No notifications in this window — pinned chats still come through. Messages arrive either way.', 'quietFrom': 'From', 'quietTo': 'Until',
    'trustTitle': 'Trusted contacts', 'trustSub': 'Split your 12 words into parts for friends. A few of them together restore your identity — one alone reveals nothing.', 'trustCreate': 'Create parts', 'trustHow': 'How many parts, and how many are needed to restore?', 'trustSheetTitle': 'Any {k} of these {n} parts restore your identity', 'trustWarn': 'Give each part to a different person. Nobody may hold {k} parts — together they are your identity.', 'trustPart': 'PART', 'trustSend': 'Send to…', 'trustMsg': 'This is a recovery part for my BitDM identity. Please keep this message and do not forward it. Only send it back if I ask you in person.', 'trustSent': 'Part sent', 'trustNoContacts': 'No contacts yet', 'restoreParts': 'Instead of the words you can paste the parts from your trusted contacts — all into this field.', 'restorePartsBad': 'The parts do not fit together:',
    'attachOnce': 'Photo, view once', 'onceTag': 'View once', 'onceSent': 'sent', 'onceView': 'View', 'oncePlay': 'Play', 'onceViewed': 'Viewed — gone', 'onceOnlyImages': 'View once works with photos (and voice messages via 1× while recording).', 'onceToggle': 'Send as view once', 'imageUnreadable': 'This image cannot be shown here.',
    'listCreate': 'New distribution list', 'listName': 'List name', 'listTag': 'LIST', 'listExplain': 'One message, sent separately to each person. Nobody sees who else got it — it arrives as a normal one-to-one message.', 'listDelete': 'Delete list', 'listSent': 'Sent to {n}', 'listInvalid': 'A name and at least one contact.',
    'backupFilesAsk': 'Include the downloaded attachments themselves? Up to 100 MB fit, smallest first; view-once media never. Without them the backup stays small, and attachments can be fetched again only while they are still in the relay store (14 days).', 'backupNoFiles': 'Without files', 'backupWithFiles': 'With files',
    'msgInfo': 'Delivered to', 'msgInfoSub': 'Two ticks: arrived on that member\'s device. The message shows two ticks once every member has it.',
    'torTitle': 'Connect via Tor', 'torSub': 'Everything to the relay and the attachment store goes through Orbot (SOCKS5 on 127.0.0.1:{port}). The relay is reached as an onion service, so neither it nor a Tor exit sees your IP address. Orbot must be running; nearby mode is not affected.',
    'wipeTitle': 'Remote wipe by trusted contacts', 'wipeSub': 'If your phone is lost or seized, several trusted contacts together can have it wiped.', 'wipeSetup': 'Set up', 'wipeOn': 'On — {k} of {n} contacts', 'wipeExplain': 'How it works:\n• Only the contacts you tick below can trigger it — nobody else.\n• At least as many different ones as you choose (k of n) must ask within 24 hours.\n• Then a 10-minute countdown runs with a notification. You can cancel it in the app — only with your unlock.\n• After that, everything on this device is deleted: identity, contacts, messages, attachments. Your 12 words still restore the identity on another device.\n• Your trusted contacts ask either with the /wipe command or by writing your code word to you. Tell them the code word yourself, in person.\n• Limit: it only works while BitDM on this phone is unlocked and online. A locked phone cannot read the request.', 'wipeEnable': 'Allow remote wipe', 'wipeThreshold': 'How many must ask', 'wipeTooFew': 'Pick at least {k} contacts.', 'wipeAskTitle': 'Ask for a remote wipe?', 'wipeAskText': 'This asks {id} to wipe their phone. It only happens if they made you a trusted contact and enough others ask too. Only do this if they asked you to.', 'wipeSend': 'Send request', 'wipeSent': 'Wipe request sent', 'wipeBanner': 'Remote wipe in {m} min — requested by your trusted contacts.', 'wipeCancelled': 'Remote wipe cancelled', 'wipeNotify': 'BitDM needs your attention.', 'cmd_wipe': 'Ask this contact\'s phone to wipe itself (trusted contacts only)',
    'coverTitle': 'Cover traffic', 'coverSub': 'While connected, send frames at random times that look like messages from the outside. Hides when you really write from anyone watching the network (not from the relay). Costs a little data.',
    'notesEmpty': 'Nothing noted yet',
    'themeDrift': 'Drifting themes', 'themeDriftSub': 'The dark themes slowly re-key into one another.',
    'decryptFx': 'Decrypt effect', 'decryptFxSub': 'New messages resolve out of cipher text.',
    'panicPw': 'Panic word', 'panicPwSub': 'A word or sentence. Typed at the lock screen instead of your password, it deletes everything instead of unlocking.',
    'panicPwBody': 'If you are ever forced to unlock, type this word or sentence at the lock screen instead of your real password. BitDM then silently deletes this identity, all contacts and all messages, and looks freshly installed.\n\nAt least 4 characters; spaces inside are fine. Every character counts exactly as you type it here, including upper and lower case. It cannot be your real password.',
    'panicPwSame': 'That is your real password. Choose a different word.',
    'typingSetting': 'Typing indicator', 'typingSettingSub': 'Default: off. Only shown if both sides have it on.',
    'archived': 'Archived', 'backToChats': 'Back to chats', 'search': 'Search messages', 'noResults': 'Nothing found',

    // ---- Anhaenge ----
    // "Holen" statt "Herunterladen": eine Datei kann drei Gigabyte gross sein,
    // und der Nutzer entscheidet ausdruecklich. Das Wort soll klingen wie eine
    // Entscheidung, nicht wie ein Automatismus.
    'attach': 'Attach file', 'attachSend': 'Sending', 'attachGet': 'Get file',
    'attachAgain': 'Try again', 'attachOpen': 'Open', 'attachGone': 'No longer stored',
    'attachGoneWhy': 'Attachments are kept for 14 days, and vanish once fetched.',
    'attachHere': 'On this device',
    'attachTooBig': 'That file is too large. BitDM carries up to 5 GB.',
    'attachFull': 'The storage is full right now. Try again later.',
    'attachQuota': "Today's limit is used up. Attachments are capped at 10 GB per day.",
    'attachBroken': "That file did not come through intact. Ask the sender to send it again.",
    'attachNet': 'That did not go through. Check the connection and try again.',
    'attachWeb': 'Files do not work in the browser — that needs the app.',
    'attachNoPicker': 'There is no file picker on this system — that needs the app for Android, Windows or Linux.',
    'webOnboard': 'Browser version, limited. Without an app password your identity '
        'only lasts until the page is reloaded — after that you get it back with '
        'your 12 words. With an app password it stays in this browser, encrypted. '
        'Nearby radio, files and voice messages are app-only.',
    'webVolatile': 'Browser: without an app password your identity is gone when '
        'the page reloads. Set one under Settings › Access, then it stays here, '
        'encrypted.',
    'attachBusy': 'One file at a time — wait for the current one.',
    'attachNoApp': 'No app on this device can open that kind of file.',
    'attachUnreadable': 'This attachment could not be decrypted on this device.',
    'attachMissing': 'The file of this attachment is no longer on this device.',

    // ---- Verbindungstest ----
    'connTest': 'Check connection',
    'connTestSub': 'Goes through every link in the chain and says which one '
        'does not hold.',
    'connTestStart': 'Run the test',
    'connTestAgain': 'Run again',
    'connTestRunning': 'testing…',
    'connLast': 'Last technical error',
    'connTestRow': 'Check connection',
    'connTestRowSub': 'Find out what exactly is not working.',
    'pruefIdentitaet': 'Identity on this device',
    'pruefNahbereich': '“Nearby only” is on',
    'pruefNahbereichWas': 'That is why nothing below was tested — the switch '
        'stops BitDM from touching any server at all.',
    'pruefFunk': 'Nearby over Bluetooth',
    'pruefTor': 'Tor proxy (Orbot)',
    'pruefRelay': 'Connection to the relay',
    'pruefAngemeldet': 'The relay knows this address',
    'pruefLager': 'Attachment storage, all the way',

    // ---- Anleitung: nur in der Naehe ----
    // AM KERN NACHGEPRUEFT AM 15.10.2026. Bis dahin stand oben "die Zustellung
    // ueber Funk ist noch nicht gebaut" und in Schritt 4, Android brauche die
    // Ortung. Beides war falsch: die Zustellung laeuft (wegwahl.dart,
    // test/nah/nahweg_test.dart), und das Manifest fragt den Standort mit
    // Absicht nicht ab (BLUETOOTH_SCAN mit neverForLocation, Nahbereich erst
    // ab Android 12).
    //
    // "VORHER MIT INTERNET" STIMMT, nur der alte Grund nicht. Das
    // Schluesselbuendel reist inzwischen auch ueber Funk — die Kontaktanfrage
    // aber nicht: mit "nur in der Naehe" geht sie nicht hinaus und wird erst
    // beim naechsten Verbinden mit dem Relay nachgeschickt
    // (_wiederholeKontaktanfragen, nur aus connect()). Schreiben laesst die
    // Oberflaeche erst, wenn der Kontakt bestaetigt ist (reqSentNote).
    // Festgehalten in nahweg_test, "EIN NEUER KONTAKT ENTSTEHT NICHT UEBER
    // FUNK" — wer das aendert, muss diese Texte mit aendern.
    'nearGuide': 'Nearby only, step by step',
    'nearGuideLink': 'How this works',
    'nearGuideKurz': 'Messages go from phone to phone over Bluetooth, with no '
        'server in between — but only to contacts that are already confirmed, '
        'and only over a few metres. Everything else waits until you switch it '
        'off again.',
    'nearGuideWhat': 'What it does',
    'nearGuideWhatBody': 'BitDM stops talking to any server. No connection, no '
        'sign-in, not even a lookup. A message to a contact in Bluetooth range '
        'goes straight to their phone and is marked “Direct”. Everything else '
        'stays on this phone and goes out the moment you switch it off again — '
        'it is not lost.',
    'nearGuideSteps': 'What to do',
    'nearStep1': 'Become contacts first — with the internet still on',
    'nearStep1Body': 'One of you adds the other by QR code or address, the other '
        'accepts the request. The request only travels via the relay, and over '
        'Bluetooth BitDM only finds people who are already contacts. Someone you '
        'add while the switch is on stays a pending request until you switch it '
        'off.',
    'nearStep2': 'Both of you switch on both switches',
    'nearStep2Body': '“Use Bluetooth” and “Nearby only”, on both phones. '
        'Without “Use Bluetooth” nothing goes out or comes in over the air. Each '
        'switch only speaks for its own phone: whoever has “Nearby only” off '
        'keeps sending via the server when it is reachable — and that reaches '
        'you only once you switch yours off.',
    'nearStep3': 'Stay within a few metres',
    'nearStep3Body': 'It was measured at two metres in the same room; walls '
        'shorten the reach. This is meant for the same room, not the same '
        'building.',
    'nearStep4': 'Leave Bluetooth on — location is not needed',
    'nearStep4Body': 'BitDM asks once for the Bluetooth permission and never for '
        'your location: its scan is declared as not locating you, which is why '
        'nearby needs Android 12. Both phones also need Bluetooth 5; an older '
        'one cannot take part.',
    'nearStep5': 'Do not expect attachments',
    'nearStep5Body': 'They need the storage server. With the switch on they are '
        'refused straight away, with a message that says so.',
    'nearGuideBack': 'Switching it off again',
    'nearGuideBackBody': 'Everything that was waiting goes out at once, in the '
        'order you wrote it — contact requests included. Nothing needs to be '
        'repeated by hand.',
    'nearGuideLimits': 'What it does not do',
    'nearGuideLimitsBody': 'It is not a flight mode. Other apps are unaffected, '
        'and this phone keeps its internet connection — only BitDM stops using '
        'it. Someone watching your network sees that BitDM went quiet.',

    // ---- Nur in der Naehe ----
    // Der Text sagt zuerst, was der Schalter WIRKLICH tut (kein Server), und
    // erst dann, was er noch nicht kann. Umgekehrt haette niemand den Grund
    // verstanden, aus dem man ihn umlegt.
    'nearOnly': 'Nearby only',
    'nearOnlySub': 'BitDM contacts no server at all — not even to connect.',
    'nearOnlyNow': 'What that means right now',
    'nearOnlyWarn': 'Nothing leaves this phone. With Bluetooth off there is no '
        'way out at all: messages stay put and go the moment you switch one of '
        'the two back on. Attachments are impossible — they need the storage '
        'server.',
    // Zweite Fassung fuer den Fall, dass Bluetooth AN ist. Ohne sie stuende
    // "es gibt keinen Weg hinaus" direkt unter einem eingeschalteten
    // Bluetooth-Schalter — beides zusammen liest sich wie ein Fehler, auch
    // wenn jeder Satz fuer sich stimmt.
    //
    // Seit die Wegwahl am Nachrichtenweg haengt, traegt Bluetooth wirklich
    // Nachrichten. Hier stand bis dahin, dass dieser letzte Schritt noch
    // gebaut werde — ein Satz, der jetzt eine Zusage kleinredet, die die App
    // einhaelt.
    //
    // Bis 15.10.2026 stand hier ausserdem, auch die allererste Nachricht an
    // einen ganz neuen Kontakt gehe so. Fuer den Kern stimmt das (das Buendel
    // kommt per Funk), fuer den Nutzer nicht: einen ganz neuen Kontakt gibt
    // es hier nur als ausstehende Anfrage, und die geht nicht ueber Funk —
    // siehe den Kopf der Anleitung oben. Und "nichts verlaesst dieses
    // Telefon" stand direkt vor "Nachrichten gehen direkt an Kontakte".
    'nearOnlyWarnRadio': 'No server is contacted. Messages go straight to '
        'contacts in Bluetooth range; everything else waits until you turn this '
        'off again. That only reaches confirmed contacts — someone you add now '
        'stays a pending request until then, because the request needs the '
        'relay. Attachments do not work either way, they need the storage '
        'server.',
    'nearOnlyNoAttach': 'Not while “nearby only” is on — an attachment needs the storage server.',
    'nearOnlyWaiting': 'Nearby only · messages are waiting',

    // ---- Der Funk selbst ----
    // Zwei Schalter, nicht einer: "Bluetooth benutzen" ist die
    // Ausfallsicherung, "nur in der Naehe" die Einschraenkung. Der Text muss
    // den Unterschied tragen, sonst legt jemand den falschen um.
    'nearby': 'Nearby',
    'autoScroll': 'Follow new messages',
    'autoScrollSub': 'Jump to the newest message. Not while you are reading further up.',
    'addContact': 'Add contact',
    'removeContact': 'Remove contact',
    'removeAsk': 'Remove this contact and the whole conversation? This cannot be undone.',
    'removeDo': 'REMOVE',
    'nearbyUse': 'Use Bluetooth',
    'nearbyUseSub':
        'Reach contacts in range directly when the relay cannot be reached.',
    'nearbyTooOld': 'Needs Android 12. Below that, Android counts a Bluetooth '
        'scan as locating you and demands location access — and that is one '
        'permission BitDM will not ask for.',
    'nearbyNoHardware': 'This phone has no Bluetooth LE.',
    'nearbyBtOff': 'Bluetooth is switched off.',
    'nearbyNoPerm': 'BitDM is not allowed to use Bluetooth yet.',
    'nearbyAllow': 'Allow',
    'nearbyBlocked': 'Denied, and Android will not ask again. Only the system '
        'settings can change that now.',
    'nearbyOpenSettings': 'Open settings',
    // Was es KOSTET, nicht nur was es kann. Wer das erst hinterher merkt,
    // schaltet es ab und traut der naechsten Zusage weniger.
    'nearbyCost': 'Costs battery. Anyone in range can tell that some device is '
        'broadcasting — but only people you have as contacts can tell it is you.',
    'nearbyNeedsBoth': 'Switch this on too, or messages just wait.',

    // ---- Das Zeichen an einer Nachricht ----
    // Die EINZIGE Stelle, an der die Naehe sichtbar wird. Es gibt bewusst
    // keine Anzeige, wer gerade in Reichweite ist: hier steht, wie eine
    // Nachricht gegangen IST, nicht wo jemand gerade IST.
    'viaNearby': 'Direct',
    'viaNearbyTitle': 'Sent directly',
    'viaNearbyWhat': 'This message went from phone to phone over Bluetooth. No '
        'server was involved — not even one that would have seen that the two '
        'of you wrote to each other at all.',

    // ---- Anwesenheit je Kontakt ----
    'presence': 'Show presence',
    'presenceSub': 'Off: this contact cannot find you over Bluetooth, and you '
        'cannot find them. Messages then always take the relay.',

    'hintShot': 'Screenshot protection on', 'hintEnc': 'End-to-end encrypted', 'hintEph': 'Messages delete after ',

    // ---- Frische Anmeldung, Woerter, Metadaten, Fernloeschung ----
    // Die Warnung der Fernloeschung ist mit Absicht neutral: die
    // Benachrichtigung sieht auch, wer das Telefon gerade nicht haben sollte.
    'confirmTitle': 'Are you sure?', 'confirmYes': 'Yes',
    'freshAuthTitle': 'Confirm it is you',
    'freshAuthPw': 'Enter your app password to continue.',
    'freshAuthNone': 'None of your unlock methods works on this device.',
    'phraseShow': 'Show recovery words',
    'phraseShowSub': 'The 12 words that restore your identity. Asks for your unlock first.',
    'phraseShowWarn': 'Anyone who sees these words can be you. Do not photograph them, do not type them anywhere.',
    'phraseShowFailed': 'The words could not be loaded.',
    'copiedSecret': 'Copied — the clipboard is cleared in 30 seconds',
    'wipeBannerSec': 'Remote wipe in {s} s — requested by your trusted contacts.',
    'wipeCancelAsk': 'Stop the remote wipe that your trusted contacts requested?',
    'wipeChangeAsk': 'Change or turn off remote wipe?',
    'metaAskTitle': 'Metadata stays in the file',
    'metaTooBig': 'This file is too large to remove its metadata (location, camera, time). Send it anyway?',
    'metaFailed': 'The metadata (location, camera, time) could not be removed from this file. Send it anyway?',
    'metaNotRemoved': 'Not sent: the metadata could not be removed.',
    'sendAnyway': 'Send anyway',
    'listSentFailed': 'Sent to {n}, failed for {f}',
    'phraseInvalid': 'These words are not a valid recovery phrase.',
    'pushForeign': 'The push distributor named a server that is not ours. It was ignored.',
    'wipeHow': 'How it works',
    'wipeCode': 'Code word',
    'wipeCodeNone': 'No code word set. Trusted contacts can only use /wipe.',
    'wipeCodeIsSet': 'Code word set. Only a check value is stored — the word itself cannot be read back.',
    'wipeCodeSet': 'Set code word',
    'wipeCodeChange': 'Change',
    'wipeCodeRemove': 'Remove',
    'wipeCodeTitle': 'Code word for remote wipe',
    'wipeCodeBody': 'A word or sentence, at least 6 characters. If a trusted contact writes you exactly this, it counts as a wipe request — the message does not appear in the chat. Upper/lower case and extra spaces do not matter. Tell your trusted contacts in person, not via BitDM. From anyone else it is just a normal message.',
    'wipeCodeHint': 'Code word',
    'wipeCodeAgain': 'Again',
    'wipeCodeShort': 'At least 6 characters.',
    'wipeCodeSaved': 'Code word saved',
    'wipeCodeRemoved': 'Code word removed',
    'wipeCodeAsk': 'Change the code word for remote wipe?',
    'wipeCodeRemoveAsk': 'Remove the code word? Trusted contacts can then only use /wipe.',
    'panicPwNoPw': 'You unlock without an app password (fingerprint or device PIN)? The lock screen still shows the "App password" button. Type the panic word there.',
    'panicPwHint': 'Panic word or sentence',
    'panicPwAgain': 'Again',
    'panicPwShort': 'At least 4 characters.',
    'panicPwEdge': 'Please no spaces at the beginning or end.',
    'updateAvail': 'BitDM {neu} is available. You can update, but you don\'t have to.',
    'updateSite': 'To the website',
    'updateReload': 'Reload',
    'updateLater': 'Later',
    'updateNotif': 'BitDM {neu} is available.',
    'keyArtLabel': 'Key image',
    // Schluesselspeicher beim Start nicht lesbar (AppState.schluesselspeicherZu).
    'keyStoreTitle': 'Key not reachable',
    'keyStoreLinux': 'No keyring is reachable, or it is locked. BitDM keeps the key to your identity there and cannot open without it.\n\nStart or unlock GNOME Keyring or KWallet, then try again.',
    'keyStoreOther': 'The key store of this device did not answer. BitDM keeps the key to your identity there and cannot open without it.\n\nTry again in a moment. If it keeps failing, restart the device.',
    'keyStoreSafe': 'Nothing was deleted and no new identity was created. If there is an identity on this device, it is still there.',
    'keyStoreRetry': 'Try again',
    'keyStoreTrying': 'Trying …',
  },
  'de': {
    'h1a': 'Kein Name.', 'h1b': 'Keine Nummer.',
    'intro': 'BitDM erzeugt eine Identität auf diesem Gerät. Du erhältst eine lange ID — sie ist alles, was andere brauchen, um dich hinzuzufügen.',
    'b1': 'Keine Telefonnummer, keine E-Mail', 'b2': 'Schlüssel verlassen das Gerät nicht', 'b3': 'Kein Konto, keine Wiederherstellung',
    'create': 'Identität erstellen', 'actCreate': 'Erstellen', 'actSave': 'Speichern', 'createNote': 'Dauert unter einer Sekunde. Offline möglich.',
    'restoreLink': 'Ich habe schon 12 Wörter',
    'restoreLinkSub': 'Telefon verloren oder gewechselt? Hier holst du deine Identität zurück.',
    'restoreTitle': 'Identität wiederherstellen',
    'restoreIntro': 'Gib die 12 Wörter in der Reihenfolge ein, in der du sie notiert hast. Die Reihenfolge zählt — dieselben Wörter in anderer Folge sind eine andere Identität.\n\nAlte Nachrichten kommen nicht mit. Dieses Gerät beginnt mit einer leeren Unterhaltungsliste und sieht ab jetzt alles Neue.\n\nBenutzt schon ein anderes Gerät diese Wörter, bleibt es angemeldet und bekommt weiter jede neue Nachricht — abmelden lässt sich ein Gerät nicht. Wurde dein altes Telefon ohne App-Sperre gestohlen, ist eine neue Identität sicherer.',
    'restoreHint': 'wort1 wort2 wort3 …',
    'restoreDo': 'Wiederherstellen',
    'restoreCount': 'Das sind {n} Wörter, es braucht {soll}.',
    'restoreUnknownWord': 'Ein Wort steht nicht in der Liste — es ist oben markiert. Meistens ein Tippfehler.',
    'restoreChecksum': 'Jedes Wort für sich ist gültig, zusammen ergeben sie aber nichts. Meist sind zwei vertauscht, oder eines ist ein anderes Wort aus derselben Liste. Prüfe die Reihenfolge.',
    'restoreNote': 'Was zurückkommt: deine Identität und deine Adresse — man kann dich wieder erreichen. Was NICHT zurückkommt: deine Nachrichten und Kontakte. Die lagen nur auf dem alten Telefon, verschlüsselt, und kein Server hatte je eine Kopie. Das ist kein Mangel, sondern der Grund, warum sie auch sonst niemand lesen konnte.',
    'wiped': 'Alle Daten wurden gelöscht. Die alte Identität ist nicht wiederherstellbar.',
    'creating': 'Identitaet wird angelegt',
    'phraseTitle': 'Deine 12 Woerter',
    'phraseSub': 'Das ist der einzige Weg zurueck, wenn dieses Telefon verloren, kaputt oder geloescht ist. Es gibt keinen Server, der sie wiederherstellen koennte.',
    'phraseWarn': 'Schreib sie auf Papier, in dieser Reihenfolge. Wer sie hat, IST du. Niemals abfotografieren, niemals auf einer Webseite eingeben.',
    'phraseDone': 'Habe ich notiert',
    'noChats': 'Noch keine Unterhaltungen. Teile deine ID, damit dich jemand hinzufuegen kann.\n\nWenn du hier deine 12 Wörter eingegeben hast: alte Nachrichten bleiben auf dem anderen Gerät. Alles Neue erscheint auf beiden.',
    'badAddress': 'Das ist keine gueltige BitDM-ID. Pruefe auf Tippfehler — die ID traegt eine Pruefsumme.',
    'tooLong': 'Diese Nachricht ist zu lang. BitDM trägt bis zu 4096 Zeichen auf einmal — teile sie in zwei.',
    'safetyNumber': 'Pruefnummer',
    'verifyNoSession': 'Verfuegbar, sobald ihr eine Nachricht ausgetauscht habt. Die Nummer entsteht aus beiden Schluesseln.',

    'scanHint': 'Halte die Kamera auf den QR-Code des anderen. Es wird nichts gespeichert und nichts gesendet - das Bild wird nur auf diesem Geraet gelesen.',
    'scanNoCamera': 'Keine Kamera verfuegbar. Ohne Kamerazugriff laesst sich der Code nicht lesen - du kannst die Adresse stattdessen einfuegen.',
    'waitingForAccept': 'Anfrage gesendet — wartet auf Bestaetigung',
    'locked': 'Gesperrt',
    'lockedSub': 'Die Identität auf diesem Telefon ist verschlossen. Sie geht nur mit einem eingerichteten Faktor auf — der Schlüssel selbst liegt nirgends lesbar auf diesem Gerät, auch nicht mit Root, auch nicht mit der Datei in der Hand.',
    'unlock': 'Entsperren',
    'unlockStick': 'Mit Sicherheitsschlüssel',
    'lockedNoFactor': 'Zu dieser Identität ist kein brauchbarer Faktor eingerichtet. Vermutlich ist die Fachdatei beschädigt. Deine 12 Wörter holen die Identität auf einem anderen Gerät zurück — die Nachrichten auf diesem Telefon sind verloren.',
    'stickIntro': 'Der Schlüssel trägt ein Geheimnis, das sich nicht von ihm herunterkopieren lässt. Das Einrichten braucht ZWEI Berührungen: eine, um den Zugang anzulegen, eine, um das Geheimnis zu holen. Das ist kein Fehler — anders geht es nicht.',
    'stickUsb': 'Einstecken',
    'stickNfc': 'Auflegen',
    'stickPinLabel': 'PIN des Schlüssels',
    'stickPinHint': 'Die PIN des Sicherheitsschlüssels, nicht die dieses Telefons. Sie verlässt das Telefon nie im Klartext. Leer lassen, wenn der Schlüssel keine hat.',
    'stickWorking': 'Berühre den Schlüssel, wenn er blinkt — zweimal.',
    'stickPinWrong': 'PIN falsch.',
    'stickPinWrongLeft': 'PIN falsch. Noch {n} Versuche, dann sperrt sich der Schlüssel endgültig.',
    'stickPinNeeded': 'Dieser Schlüssel hat eine PIN. Gib sie oben ein.',
    'stickLostNote': 'Geht der Schlüssel verloren, lässt sich dieses Fach nicht mehr öffnen. Richte einen zweiten Faktor ein. Deine 12 Wörter holen die Identität auf einem anderen Gerät zurück.',
    'lockNoScreenLock': 'Keine Bildschirmsperre eingerichtet',
    'lockNoScreenLockBody': 'Dieses Telefon hat keine Bildschirmsperre, also gibt es nichts, woran sich der Schluessel binden liesse. Richte in den Android-Einstellungen zuerst einen Fingerabdruck oder eine PIN ein — eine Sperre, die jeder oeffnet, waere keine.',
    'notifOne': 'Neue Nachricht',
    'notifMany': '{n} neue Nachrichten',
    'fidoProbe': 'Sicherheitsschluessel pruefen',
    'fidoHold': 'Halte deinen Sicherheitsschluessel an die Rueckseite des Telefons. Es geht genau ein Befehl raus: die Frage, was der Stick kann. Es wird nichts angelegt, nichts geaendert und keine PIN verlangt.',
    'fidoNoNfc': 'NFC ist aus oder nicht verfuegbar. In den Android-Einstellungen einschalten.',
    'myId': 'Meine ID', 'myIdSub': 'Teile sie, damit dich jemand hinzufügen kann.', 'share': 'Teilen', 'copy': 'Kopieren', 'copied': 'Kopiert',
    'myIdEmpty': 'Noch keine Identität. Leg auf dem Startbildschirm eine an oder hol eine bestehende aus deinen 12 Wörtern zurück — dann steht deine ID hier.',
    'idNote': 'Die ID enthält keinen privaten Schlüssel. Details unter Einstellungen › Sicherheit.',
    'geraeteEins': 'Ein Gerät benutzt diese Identität.',
    'geraeteViele': '{n} Geräte benutzen diese Identität — wer deine 12 Wörter hat, bekommt von jeder Nachricht eine eigene Kopie. Ein Gerät abmelden geht nicht.',
    // Geraeteliste (docs/GERAETEABMELDUNG.md). Der Satz oben gilt nur noch
    // bei einem Relay ohne Geraeteliste.
    'geraeteVieleListe': '{n} Geräte benutzen diese Identität. Jedes musste auf einem Gerät bestätigt werden, das du schon hattest — und jedes kannst du abmelden.',
    'geraeteVerwalten': 'Geräte verwalten',
    'geraeteTitel': 'Geräte',
    'geraeteDieses': 'dieses Gerät',
    'geraeteSeit': 'seit {d}',
    'geraeteOhneName': 'Gerät {n}',
    'geraeteAbmelden': 'Abmelden',
    'geraeteAbmeldenFrage': '{name} abmelden? Es bekommt ab sofort keine Nachrichten mehr und vergisst deine 12 Wörter. Seine Unterhaltungen bleiben dort verschlüsselt liegen; nur deine 12 Wörter öffnen sie wieder.',
    'geraeteDiesesAbmelden': 'Dieses Gerät abmelden',
    'geraeteDiesesAbmeldenFrage': 'Dieses Gerät abmelden? Es vergisst deine 12 Wörter und bekommt keine Nachrichten mehr. Deine anderen Geräte laufen weiter.',
    'geraeteAlleAnderen': 'Alle anderen abmelden',
    'geraeteAlleAnderenFrage': 'Alle Geräte außer diesem abmelden?',
    'geraeteHinzufuegen': 'Gerät hinzufügen',
    'geraeteCodeTitel': 'Code für das neue Gerät',
    'geraeteCodeText': 'Gib auf dem neuen Gerät deine 12 Wörter ein und dann diesen Code. Er gilt einmal und 10 Minuten lang. Niemand sonst sieht ihn — auch der Server nicht.',
    'geraeteCodeWartet': 'Warte auf das neue Gerät …',
    'geraeteHinzugefuegt': 'Gerät hinzugefügt.',
    'geraeteVoll': 'Diese Identität hat schon 5 Geräte. Melde erst eines ab.',
    'geraeteKeineListe': 'Dieser Server kennt noch keine Geräteliste. Ein Gerät abmelden geht erst nach seinem Update.',
    'geraeteFehler': 'Das hat nicht geklappt. Verbindung prüfen und noch einmal versuchen.',
    'geraeteWoerterHinweis': 'Wer deine 12 Wörter kennt, kann alle deine Geräte abmelden und selbst übernehmen. Ist das passiert — etwa weil das Telefon entsperrt gestohlen wurde oder die Wörter herumlagen —, hilft nur eine neue Identität.',
    'beitrittTitel': 'Dieses Gerät ist noch nicht bestätigt',
    'beitrittText': 'Deine Identität ist schon auf einem anderen Gerät angemeldet. Öffne dort Einstellungen › Meine ID › Geräte verwalten › Gerät hinzufügen und gib den Code hier ein.',
    'beitrittCode': 'Code vom anderen Gerät',
    'beitrittSenden': 'Bestätigen lassen',
    'beitrittWartet': 'Warte auf das andere Gerät …',
    'beitrittAbbrechen': 'Abbrechen',
    'beitrittCodeFalsch': 'Das ist kein gültiger Code (16 Zeichen).',
    'beitrittKeinGeraet': 'Kein anderes Gerät mehr?',
    'beitrittZuruecksetzen': 'Alle anderen Geräte abmelden',
    'beitrittZuruecksetzenFrage': 'Alle anderen Geräte dieser Identität werden abgemeldet und bekommen ab sofort nichts mehr. Nimm das, wenn dein Telefon weg ist. Wer deine 12 Wörter kennt, kann dasselbe tun — war das Telefon entsperrt oder sind die Wörter nicht sicher, leg danach eine neue Identität an.',
    'abgemeldetHinweis': 'Dieses Gerät wurde abgemeldet{von}. Deine Unterhaltungen liegen verschlüsselt hier; mit deinen 12 Wörtern holst du sie zurück — ein anderes Gerät muss das dann bestätigen.',
    'abgemeldetVon': ' von {name}',
    'connBeitritt': 'Gerät nicht bestätigt',
    'shareFailed': 'Es wurde keine App zum Teilen gefunden.',
    'addTitle': 'Kontakt hinzufügen', 'idLabel': 'BitDM-ID', 'paste': 'Einfügen', 'scan': 'QR scannen', 'sendReq': 'Anfrage senden',
    'pending': 'Ausstehend', 'reqSentNote': 'Anfrage gesendet. Der Chat öffnet sich, sobald die Gegenseite bestätigt.',
    'peerNeedsUpdate': 'Die Gegenseite muss BitDM aktualisieren (ab 2.0). Bis dahin warten deine Nachrichten hier und gehen danach von selbst hinaus.',

    'addFoot': 'Vor der Bestätigung werden keine Nachrichten übertragen. Ein Kontakt kann jederzeit einseitig entfernt werden.',
    'chats': 'Chats', 'connOnline': 'verbunden', 'connConnecting': 'verbindet', 'connOffline': 'offline', 'connError': 'keine Verbindung', 'connGeraeteVoll': 'zu viele Geräte', 'wantsChat': 'Möchte einen verschlüsselten Chat mit dir beginnen.', 'accept': 'Annehmen', 'decline': 'Ablehnen',
    'noNames': 'Kontakte erscheinen als ID und Muster. Namen gibt es nicht — auch nicht lokal.',
    'encDetails': 'Verschlüsselt · Details', 'message': 'Nachricht', 'send': 'Senden',
    'encryption': 'Verschlüsselung', 'protocol': 'Protokoll', 'sessionKey': 'Sitzungsschlüssel', 'selfDestruct': 'Selbstlöschende Nachrichten',
    'selfDestructSub': 'Optional, pro Gerät', 'readReceipts': 'Lesebestätigungen', 'readReceiptsSub': 'Standard: an',
    'verifyNote': 'Vergleiche den Sitzungsschlüssel persönlich, um die Gegenseite zu verifizieren.', 'close': 'Schließen',
    'secureTitle': 'Gerät absichern', 'secureSub': 'Deine Identität liegt nur hier. Richte mindestens einen Nachweis ein, bevor die App entsperrt.',
    'secureFoot': 'Faktoren lassen sich später unter Einstellungen › Zugriff ergänzen oder entfernen.', 'secureSkip': 'Später', 'secureDone': 'Weiter',
    'access': 'Zugriff', 'on2': 'Aktiv', 'offMethod': 'Nicht eingerichtet', 'add': 'Einrichten', 'remove': 'Entfernen',
    'bio': 'Biometrie', 'bioSub': 'Fingerabdruck oder Gesichtsentsperrung dieses Geräts',

    'devpin': 'Gerätesperre', 'devpinSub': 'Die PIN, das Muster oder das Passwort dieses Telefons',
    'pw': 'App-Passwort', 'pwSub': 'Ein Passwort nur für BitDM — bleibt in deinem Kopf',
    'enrollPw': 'App-Passwort festlegen',
    'pwIntro': 'Dieses Fach hängt an NICHTS außer dem Passwort. Kein gesicherter Bereich, kein Schlüssel. Wer die Fachdatei kopiert, kann auf eigener Hardware probieren, so lange er will — Argon2id verteuert jeden Versuch, aber aus einem kurzen Passwort macht es kein langes.',
    'pwHint': 'Passwort',
    'pwAgain': 'Wiederholen',
    'pwMismatch': 'Die beiden Eingaben sind verschieden.',
    'pwWeak': 'Zu kurz. Das gibt rund {ist} Bit her, nötig sind mindestens {soll}. Vier oder fünf zufällige Wörter merkt man sich leichter als ein kurzes kryptisches — und sie sind erheblich stärker.',
    'pwLostNote': 'Vergessen heißt weg. Es gibt kein Zurücksetzen. Deine 12 Wörter holen die Identität auf einem anderen Gerät zurück.',
    'pwUnlockHint': 'Dein BitDM-Passwort. Nicht die Telefon-PIN und nicht die PIN des Sicherheitsschlüssels.',
    'unlockBio': 'Fingerabdruck',
    'unlockDevPin': 'Gerätesperre',
    'unlockPw': 'App-Passwort',
    'unlockFailed': 'Damit ging das Fach nicht auf.',
    'receiving': 'Empfang',
    'bgReceive': 'Im Hintergrund empfangen',
    'bgReceiveSub': 'Ob Nachrichten ankommen, während die App zu ist',
    'bgOff': 'Aus', 'bgLive': 'Ständig', 'bg15': '15 Min.', 'bg60': '1 Std.', 'bg240': '4 Std.', 'bgPush': 'Anstoß',
    'bgOffNote': 'Nachrichten kommen an, wenn du die App öffnest. Nichts läuft im Hintergrund, nichts kostet Akku, keine dauerhafte Benachrichtigung. Reicht, wenn du ohnehin regelmäßig reinschaust — verloren geht nichts, der Relay hält Nachrichten 14 Tage.',
    'bgPushNote': 'Lohnt sich nur, wenn du OHNEHIN eine Push-App für andere Apps nutzt (Element, Tusky, FluffyChat). Dann ist BitDM gratis dabei — die Verbindung steht sowieso. Nur für BitDM die ntfy-App zu installieren bringt wenig: dann hält eben eine andere App die Verbindung. Nicht Google, so oder so: der Anstoß läuft über push.bitdm.net, denselben Betreiber wie der Relay.',
    'bgLiveNote': 'Ständig verbunden — Nachrichten kommen in dem Moment an, in dem sie gesendet werden. Kostet am meisten Akku, aber deutlich weniger, als es klingt: eine ruhende Verbindung sind ein paar Pakete pro Stunde. Nimm das, wenn dich Leute wirklich über BitDM erreichen.',
    'bg15Note': 'Verbindet sich alle 15 Minuten kurz. Fühlt sich fast wie ständig an, braucht spürbar weniger Akku als eine dauerhafte Verbindung und kommt ohne zweite App aus. Der sinnvolle Standard — nimm das, wenn nichts dagegen spricht.',
    'bg60Note': 'Einmal pro Stunde. Reicht, wenn niemand auf eine sofortige Antwort wartet. Am Akku kaum messbar.',
    'bg240Note': 'Viermal am Tag. Für alle, die BitDM eher wie ein Postfach behandeln als wie einen Chat.',
    'bgConflict': 'Das geht gerade nicht: der Relay antwortet nur auf eine Unterschrift mit deinem Identitätsschlüssel, und der liegt hinter der App-Sperre. Bei „Wieder sperren nach: Sofort" hat die App keinen Schlüssel, sobald du sie weglegst. Stell die Sperrfrist auf 5 Minuten oder Nie — oder nimm hin, dass Nachrichten beim Öffnen ankommen.',
    'bgNotifTitle': 'BitDM',
    'bgNotifText': 'Empfangsbereit',
    'pushGuideTitle': 'Anstoß einrichten',
    'pushGuideIntro': 'Anstoß braucht eine kleine Helfer-App auf dem Telefon, die eine Verbindung für alle Apps hält, die sie nutzen. BitDM nimmt ntfy. Vier Schritte, zwei Minuten.',
    'pushGuideLink': 'Anleitung nochmal zeigen',
    'pushStep1': 'ntfy installieren',
    'pushStep1Sub': 'Kostenlos und quelloffen. Beide Läden gehen — F-Droid, wenn du Google meiden willst.',
    'pushStep2': 'In ntfy den Server eintragen',
    'pushStep2Sub': 'ntfy öffnen → Einstellungen → Allgemein → „Standardserver". Was dort steht löschen und diese Adresse eintragen:',
    'pushStep3': 'Prüfen, dass UnifiedPush an ist',
    'pushStep3Sub': 'In ntfy: Einstellungen → Erweitert → „UnifiedPush aktivieren". Ist normalerweise schon an — nur zur Sicherheit.',
    'pushStep4': 'Zurückkommen und Anstoß wählen',
    'pushStep4Sub': 'Hier unter Empfang. NICHT das + in ntfy drücken — das ist für Themen, die du von Hand abonnierst. BitDM meldet sich selbst an; danach erscheint in ntfy von allein ein Abo, das mit „up" anfängt. Nicht anfassen.',
    'pushOrderWarning': 'Die Reihenfolge zählt. ntfy baut die Anstoß-Adresse aus dem Server, der IM MOMENT DES ANMELDENS eingestellt ist. Wer erst hier Anstoß wählt, bekommt eine Adresse auf ntfy.sh — BitDM lehnt sie ab, weil der Relay nur den eigenen Push-Server annimmt.',
    'pushOpenNtfy': 'ntfy öffnen',
    'pushNoNtfy': 'ntfy ist noch nicht installiert — Schritt 1.',
    'pushFailed': 'Die Push-App hat abgelehnt. Öffne ntfy einmal und versuche es erneut.',
    'lockDelay': 'Wieder sperren nach',
    'lockDelaySub': 'Wie lange die App im Hintergrund offen bleiben darf',
    'delayNow': 'Sofort', 'delay1m': '1 Min.', 'delay5m': '5 Min.', 'delayNever': 'Nie',
    'hw': 'Hardware-Sicherheitsschlüssel', 'hwSub': 'FIDO2-Schlüssel über USB-C oder NFC',

    'enrollHw': 'Schlüssel einstecken oder auflegen',

 'waiting': 'Warte auf Gerät',
    'minOne': 'Mindestens ein Faktor bleibt erforderlich.',
    'settings': 'Einstellungen', 'general': 'Allgemein', 'security': 'Sicherheit', 'identity': 'Identität', 'emergency': 'Notfall',
    'language': 'Sprache', 'languageSub': 'Gilt für die ganze App', 'appearance': 'Erscheinungsbild', 'appearanceSub': 'Standard: dunkel',
    'screenshot': 'Screenshot-Schutz', 'screenshotSub': 'Warnhinweis im Chat, Vorschau geblockt',
    'myIdQr': 'Meine ID & QR',
    'panic': 'Panik-Modus', 'panicSub': 'Identität, Kontakte und Nachrichten sofort und unwiderruflich löschen.',
    'panicTitle': 'Alles löschen?', 'panicBody': 'Diese Identität, alle Kontakte und alle Nachrichten werden von diesem Gerät entfernt. Es gibt keine Wiederherstellung.',
    'cancel': 'Abbrechen', 'delete': 'Löschen',
    'dark': 'Dunkel', 'light': 'Hell', 'off': 'Aus', 'h1': '1 Std.', 'h24': '24 Std.', 'd7': '7 Tage', 'on': 'An',
    'navChats': 'Chats', 'navId': 'Meine ID', 'navSet': 'Einstellungen',
    'voice': 'Sprachnachricht', 'newContact': 'Neuer Kontakt',
    'reply': 'Antworten', 'copyMsg': 'Kopieren', 'edit': 'Bearbeiten', 'deleteAll': 'Für alle löschen', 'deleteMe': 'Für mich löschen',
    'edited': 'bearbeitet', 'deletedMsg': 'Diese Nachricht wurde gelöscht', 'deletedMine': 'Du hast diese Nachricht gelöscht',
    'replyTo': 'Antwort auf', 'editing': 'Bearbeiten', 'replyGone': 'Ursprüngliche Nachricht nicht verfügbar', 'attachment': 'Anhang',
    'notPossible': 'Für diese Nachricht geht das nicht mehr.', 'deleteAllAsk': 'Für alle löschen?',
    'deleteAllBody': 'Die Nachricht verschwindet auf beiden Seiten. Wer sie vorher gesichert hat, hat sie trotzdem.',
    'pin': 'Anheften', 'unpin': 'Lösen', 'archive': 'Archivieren', 'unarchive': 'Zurückholen', 'mute': 'Stummschalten', 'unmute': 'Ton an',
    'chatFristStd': 'Standard', 'typing': 'tippt…', 'notes': 'Notiz an mich',
    'groupCreate': 'Neue Gruppe', 'groupName': 'Name der Gruppe', 'groupMembers': 'Mitglieder', 'groupAdmin': 'ADMIN',
    'groupYou': 'Du', 'groupAdd': 'Mitglieder hinzufügen', 'groupRemove': 'Aus der Gruppe entfernen', 'groupRename': 'Umbenennen',
    'groupLeave': 'Gruppe verlassen', 'groupNew': 'Neue Gruppe', 'groupLeft': 'Du hast diese Gruppe verlassen',
    'groupNotMember': 'Du bist nicht mehr Mitglied dieser Gruppe.',
    'groupNoContacts': 'Noch keine Kontakte zum Hinzufügen.',
    'groupInvalid': 'Eine Gruppe braucht einen Namen und 1 bis 19 weitere Mitglieder.',
    'voiceSend': 'Sprachnachricht senden', 'voiceDiscard': 'Aufnahme verwerfen', 'voicePlay': 'Abspielen',
    'micDenied': 'Für Sprachnachrichten braucht BitDM das Mikrofon.',
    'micDeniedForever': 'Das Mikrofon ist gesperrt. Für Sprachnachrichten in den Systemeinstellungen erlauben.',
    'micFailed': 'Die Aufnahme ließ sich nicht starten.',
    'backup': 'Sicherung', 'backupSub': 'Kontakte und Verlauf als verschlüsselte Datei. Sie geht nur mit deinen 12 Wörtern auf. Anhänge selbst sind nicht enthalten, Schlüssel auch nicht.',
    'backupCreate': 'Erstellen', 'backupRestore': 'Einspielen', 'backupSaved': 'Gespeichert:', 'backupRestored': 'Nachrichten dazugekommen:',
    'backupWrong': 'Diese Sicherung gehört zu einer anderen Identität oder ist beschädigt.',
    'poll': 'Umfrage', 'pollNew': 'Neue Umfrage', 'pollQuestion': 'Frage', 'pollOption': 'Antwort',
    'pollMulti': 'Mehrere Antworten erlaubt', 'pollSingle': 'Eine Antwort', 'pollInvalid': 'Eine Umfrage braucht eine Frage und 2 bis 10 Antworten.',
    'scheduleTitle': 'Später senden', 'scheduledFor': 'geplant', 'schedulePast': 'Dieser Zeitpunkt ist schon vorbei.',
    'pinMsg': 'Nachricht anheften', 'unpinMsg': 'Nachricht lösen', 'pinnedTitle': 'Angeheftete Nachrichten',
    'pinnedTag': 'Oben', 'mutedTag': 'Stumm',
    'keyArt': 'Schlüsselbild', 'keyArtSelf': 'Aus deiner Adresse gezeichnet. Deine Kontakte sehen für deinen Schlüssel dasselbe Bild.', 'keyArtPeer': 'Aus dem Schlüssel dieses Kontakts gezeichnet. Seine Einstellungen zeigen dasselbe Bild — ein schneller Abgleich, der Beweis ist die Prüfnummer.',
    'cmd_timer': 'Selbstlöschen hier: 1h · 24h · 7d · aus · std', 'cmd_verify': 'Prüfnummer zeigen', 'cmd_poll': 'Umfrage anlegen', 'cmd_shrug': 'Schulterzucken anhängen', 'cmdTimerBad': 'Zum Beispiel /timer 1h, 24h, 7d, aus oder std', 'cmdThemeBad': 'Kein Thema mit diesem Namen', 'cmdVerifyNone': 'Nur ein Einzelchat hat eine Prüfnummer',
    'star': 'Markieren', 'unstar': 'Markierung entfernen', 'starEmpty': 'Noch nichts markiert. Nachricht lange drücken und Markieren wählen — das bleibt nur auf diesem Gerät.', 'filterAll': 'Alle', 'filterUnread': 'Ungelesen', 'filterGroups': 'Gruppen', 'filterStarred': 'Markiert',
    'quietHours': 'Ruhezeiten', 'quietHoursSub': 'In diesem Fenster keine Benachrichtigungen — angeheftete Chats kommen trotzdem durch. Ankommen tut alles.', 'quietFrom': 'Von', 'quietTo': 'Bis',
    'trustTitle': 'Vertrauenskontakte', 'trustSub': 'Teile deine 12 Wörter in Stücke für Freunde. Einige zusammen stellen deine Identität wieder her — eines allein verrät nichts.', 'trustCreate': 'Teile erzeugen', 'trustHow': 'Wie viele Teile, und wie viele braucht es zum Wiederherstellen?', 'trustSheetTitle': 'Je {k} dieser {n} Teile stellen deine Identität wieder her', 'trustWarn': 'Gib jeden Teil einer anderen Person. Niemand darf {k} Teile haben — zusammen sind sie deine Identität.', 'trustPart': 'TEIL', 'trustSend': 'Senden an…', 'trustMsg': 'Das ist ein Wiederherstellungsteil für meine BitDM-Identität. Bitte diese Nachricht aufheben und nicht weiterleiten. Nur zurückschicken, wenn ich dich persönlich darum bitte.', 'trustSent': 'Teil gesendet', 'trustNoContacts': 'Noch keine Kontakte', 'restoreParts': 'Statt der Wörter gehen auch die Teile deiner Vertrauenskontakte — alle in dieses Feld.', 'restorePartsBad': 'Die Teile passen nicht zusammen:',
    'attachOnce': 'Foto, einmal ansehen', 'onceTag': 'Einmal', 'onceSent': 'gesendet', 'onceView': 'Ansehen', 'oncePlay': 'Abspielen', 'onceViewed': 'Angesehen — weg', 'onceOnlyImages': 'Einmal-Ansicht geht mit Fotos (und Sprachnachrichten über 1× beim Aufnehmen).', 'onceToggle': 'Als Einmal-Ansicht senden', 'imageUnreadable': 'Dieses Bild lässt sich hier nicht zeigen.',
    'listCreate': 'Neue Verteilerliste', 'listName': 'Name der Liste', 'listTag': 'LISTE', 'listExplain': 'Eine Nachricht, einzeln an jede Person verschickt. Niemand sieht, wer sie noch bekam — sie kommt als gewöhnliche Nachricht im Einzelchat an.', 'listDelete': 'Liste löschen', 'listSent': 'An {n} geschickt', 'listInvalid': 'Ein Name und mindestens ein Kontakt.',
    'backupFilesAsk': 'Die geholten Anhänge selbst mitsichern? Bis 100 MB passen hinein, kleinste zuerst; Einmal-Ansichten nie. Ohne bleibt die Sicherung klein, und Anhänge lassen sich nur holen, solange sie noch im Zwischenlager liegen (14 Tage).', 'backupNoFiles': 'Ohne Dateien', 'backupWithFiles': 'Mit Dateien',
    'msgInfo': 'Zugestellt an', 'msgInfoSub': 'Zwei Haken: auf dem Gerät des Mitglieds angekommen. Die Nachricht zeigt zwei Haken, sobald alle sie haben.',
    'torTitle': 'Über Tor verbinden', 'torSub': 'Alles zum Relay und ins Zwischenlager geht über Orbot (SOCKS5 auf 127.0.0.1:{port}). Der Relay wird als Onion-Dienst erreicht — weder er noch ein Tor-Ausgang sieht deine IP-Adresse. Orbot muss laufen; der Nahbereich ist davon nicht betroffen.',
    'wipeTitle': 'Fernlöschung durch Vertrauenskontakte', 'wipeSub': 'Ist dein Telefon weg oder beschlagnahmt, können mehrere Vertrauenskontakte es gemeinsam löschen lassen.', 'wipeSetup': 'Einrichten', 'wipeOn': 'An — {k} von {n} Kontakten', 'wipeExplain': 'So funktioniert es:\n• Auslösen können nur die Kontakte, die du unten ankreuzt — niemand sonst.\n• Mindestens so viele verschiedene wie gewählt (k von n) müssen binnen 24 Stunden darum bitten.\n• Dann läuft ein Countdown von 10 Minuten mit Benachrichtigung. Abbrechen kannst du ihn in der App — nur mit deiner Entsperrung.\n• Danach wird alles auf diesem Gerät gelöscht: Identität, Kontakte, Nachrichten, Anhänge. Mit deinen 12 Wörtern holst du die Identität auf einem anderen Gerät zurück.\n• Deine Vertrauenskontakte bitten entweder mit dem Befehl /wipe oder, indem sie dir dein Codewort schreiben. Das Codewort sagst du ihnen selbst, persönlich.\n• Grenze: Es wirkt nur, solange BitDM auf diesem Telefon entsperrt und online ist. Ein gesperrtes Telefon kann die Bitte nicht lesen.', 'wipeEnable': 'Fernlöschung erlauben', 'wipeThreshold': 'Wie viele müssen bitten', 'wipeTooFew': 'Wähle mindestens {k} Kontakte.', 'wipeAskTitle': 'Um Fernlöschung bitten?', 'wipeAskText': 'Damit bittest du {id}, das Telefon zu löschen. Es passiert nur, wenn du als Vertrauenskontakt eingetragen bist und genug andere ebenfalls bitten. Nur tun, wenn die Person dich darum gebeten hat.', 'wipeSend': 'Anfrage senden', 'wipeSent': 'Löschanfrage gesendet', 'wipeBanner': 'Fernlöschung in {m} Min. — angefordert von deinen Vertrauenskontakten.', 'wipeCancelled': 'Fernlöschung abgebrochen', 'wipeNotify': 'BitDM braucht deine Aufmerksamkeit.', 'cmd_wipe': 'Telefon dieses Kontakts um Löschung bitten (nur als Vertrauenskontakt)',
    'coverTitle': 'Tarnverkehr', 'coverSub': 'Solange verbunden, zu zufälligen Zeiten Rahmen senden, die von außen wie Nachrichten aussehen. Verbirgt vor jedem, der die Leitung beobachtet, wann du wirklich schreibst (nicht vor dem Relay). Kostet etwas Daten.',
    'notesEmpty': 'Noch nichts notiert',
    'themeDrift': 'Wandernde Themen', 'themeDriftSub': 'Die dunklen Themen schlüsseln sich langsam ineinander um.',
    'decryptFx': 'Entschlüsseln-Effekt', 'decryptFxSub': 'Neue Nachrichten lösen sich aus Chiffretext heraus.',
    'panicPw': 'Panik-Wort', 'panicPwSub': 'Ein Wort oder Satz. Am Sperrbildschirm statt deines Passworts eingegeben, löscht es alles, statt zu entsperren.',
    'panicPwBody': 'Wirst du je gezwungen zu entsperren, tippst du am Sperrbildschirm dieses Wort oder diesen Satz statt deines echten Passworts ein. BitDM löscht dann still diese Identität, alle Kontakte und alle Nachrichten und sieht danach aus wie frisch installiert.\n\nMindestens 4 Zeichen, Leerzeichen innen sind erlaubt. Jedes Zeichen zählt genau so, wie du es hier eingibst, auch Groß- und Kleinschreibung. Es darf nicht dein echtes Passwort sein.',
    'panicPwSame': 'Das ist dein echtes Passwort. Wähle ein anderes Wort.',
    'typingSetting': 'Tipp-Anzeige', 'typingSettingSub': 'Standard: aus. Nur sichtbar, wenn beide Seiten sie anhaben.',
    'archived': 'Archiv', 'backToChats': 'Zurück zu den Chats', 'search': 'Nachrichten durchsuchen', 'noResults': 'Nichts gefunden',

    // ---- Anhaenge ----
    'attach': 'Datei anhängen', 'attachSend': 'Wird geschickt', 'attachGet': 'Datei holen',
    'attachAgain': 'Nochmal versuchen', 'attachOpen': 'Öffnen', 'attachGone': 'Nicht mehr da',
    'attachGoneWhy': 'Anhänge liegen 14 Tage und verschwinden, sobald sie geholt wurden.',
    'attachHere': 'Auf diesem Gerät',
    'attachTooBig': 'Diese Datei ist zu groß. BitDM trägt bis zu 5 GB.',
    'attachFull': 'Der Speicher ist gerade voll. Versuch es später noch einmal.',
    'attachQuota': 'Das Tagespensum ist aufgebraucht. Anhänge sind auf 10 GB pro Tag begrenzt.',
    'attachBroken': 'Diese Datei ist nicht heil angekommen. Bitte die Gegenstelle, sie noch einmal zu schicken.',
    'attachNet': 'Das ging nicht durch. Prüf die Verbindung und versuch es noch einmal.',
    'attachWeb': 'Dateien gehen im Browser nicht — dafür braucht es die App.',
    'attachNoPicker': 'Auf diesem System gibt es keine Dateiauswahl — dafür braucht es die App für Android, Windows oder Linux.',
    'webOnboard': 'Browser-Fassung, eingeschränkt. Ohne App-Passwort bleibt deine '
        'Identität nur bis zum Neuladen der Seite — danach holst du sie mit den '
        '12 Wörtern zurück. Mit App-Passwort bleibt sie verschlüsselt in diesem '
        'Browser. Nahfunk, Dateien und Sprachnachrichten gibt es nur in der App.',
    'webVolatile': 'Browser: Ohne App-Passwort ist deine Identität beim Neuladen '
        'weg. Richte unter Einstellungen › Zugriff eines ein, dann bleibt sie '
        'hier, verschlüsselt.',
    'attachBusy': 'Eine Datei nach der anderen — warte, bis die aktuelle durch ist.',
    'attachNoApp': 'Keine App auf diesem Gerät kann diese Art Datei öffnen.',
    'attachUnreadable': 'Dieser Anhang ließ sich auf diesem Gerät nicht entschlüsseln.',
    'attachMissing': 'Die Datei dieses Anhangs liegt nicht mehr auf diesem Gerät.',

    // ---- Verbindungstest ----
    'connTest': 'Verbindung prüfen',
    'connTestSub': 'Geht jedes Glied der Kette einzeln durch und sagt, welches '
        'nicht hält.',
    'connTestStart': 'Test starten',
    'connTestAgain': 'Nochmal prüfen',
    'connTestRunning': 'wird geprüft …',
    'connLast': 'Letzter technischer Fehler',
    'connTestRow': 'Verbindung prüfen',
    'connTestRowSub': 'Herausfinden, was genau nicht geht.',
    'pruefIdentitaet': 'Identität auf diesem Gerät',
    'pruefNahbereich': '„Nur in der Nähe“ ist an',
    'pruefNahbereichWas': 'Deshalb wurde darunter nichts geprüft — der Schalter '
        'hält BitDM davon ab, überhaupt einen Server anzusprechen.',
    'pruefFunk': 'In der Nähe, über Bluetooth',
    'pruefTor': 'Tor-Proxy (Orbot)',
    'pruefRelay': 'Verbindung zum Relay',
    'pruefAngemeldet': 'Der Relay kennt diese Adresse',
    'pruefLager': 'Anhang-Speicher, den ganzen Weg',

    // ---- Anleitung: nur in der Naehe ----
    'nearGuide': 'Nur in der Nähe, Schritt für Schritt',
    'nearGuideLink': 'Wie das funktioniert',
    'nearGuideKurz': 'Nachrichten gehen über Bluetooth von Telefon zu Telefon, '
        'ohne einen Server dazwischen — aber nur an Kontakte, die schon '
        'bestätigt sind, und nur über wenige Meter. Alles andere wartet, bis du '
        'den Schalter wieder ausschaltest.',
    'nearGuideWhat': 'Was er tut',
    'nearGuideWhatBody': 'BitDM spricht keinen Server mehr an. Keine '
        'Verbindung, keine Anmeldung, nicht einmal eine Abfrage. Eine Nachricht '
        'an einen Kontakt in Bluetooth-Reichweite geht direkt auf sein Telefon '
        'und trägt das Zeichen „Direkt“. Alles andere bleibt auf diesem Telefon '
        'liegen und geht raus, sobald du ihn wieder ausschaltest — verloren ist '
        'es nicht.',
    'nearGuideSteps': 'Was zu tun ist',
    'nearStep1': 'Werdet VORHER Kontakte, mit Internet',
    'nearStep1Body': 'Einer fügt den anderen per QR-Code oder Adresse hinzu, der '
        'andere nimmt die Anfrage an. Die Anfrage geht nur über den Relay, und '
        'über Bluetooth findet BitDM nur, wer schon Kontakt ist. Wen du bei '
        'eingeschaltetem Schalter hinzufügst, bleibt eine ausstehende Anfrage, '
        'bis du ihn ausschaltest.',
    'nearStep2': 'Ihr schaltet BEIDE beide Schalter ein',
    'nearStep2Body': '„Bluetooth benutzen“ und „Nur in der Nähe“, auf beiden '
        'Telefonen. Ohne „Bluetooth benutzen“ geht über Funk nichts hin und '
        'nichts her. Jeder Schalter spricht nur für sein Telefon: wer „Nur in '
        'der Nähe“ aus hat, schickt weiter über den Server, wenn der erreichbar '
        'ist — und das kommt bei dir erst an, wenn du deinen ausschaltest.',
    'nearStep3': 'Bleibt ein paar Meter beieinander',
    'nearStep3Body': 'Gemessen ist es auf zwei Metern im selben Raum; durch '
        'Wände reicht es weniger weit. Das ist für denselben Raum gedacht, nicht '
        'für dasselbe Haus.',
    'nearStep4': 'Lasst Bluetooth an — den Standort braucht es nicht',
    'nearStep4Body': 'BitDM fragt einmal nach der Bluetooth-Berechtigung und nie '
        'nach dem Standort: die Suche ist ausdrücklich als „ortet nicht“ '
        'angemeldet, und deshalb braucht der Nahbereich Android 12. Beide '
        'Telefone brauchen außerdem Bluetooth 5; ein älteres kann nicht '
        'mitmachen.',
    'nearStep5': 'Rechnet nicht mit Anhängen',
    'nearStep5Body': 'Die brauchen den Speicherserver. Mit dem Schalter an '
        'werden sie sofort abgelehnt, mit einer Meldung, die das auch sagt.',
    'nearGuideBack': 'Wieder ausschalten',
    'nearGuideBackBody': 'Alles, was gewartet hat, geht auf einmal raus, in der '
        'Reihenfolge, in der du es geschrieben hast — Kontaktanfragen '
        'eingeschlossen. Von Hand wiederholen musst du nichts.',
    'nearGuideLimits': 'Was er nicht tut',
    'nearGuideLimitsBody': 'Er ist kein Flugmodus. Andere Apps sind unberührt, '
        'und dieses Telefon behält seine Internetverbindung — nur BitDM '
        'benutzt sie nicht mehr. Wer dein Netz beobachtet, sieht, dass BitDM '
        'still geworden ist.',

    // ---- Nur in der Naehe ----
    'nearOnly': 'Nur in der Nähe',
    'nearOnlySub': 'BitDM spricht überhaupt keinen Server an — auch nicht zum Verbinden.',
    'nearOnlyNow': 'Was das gerade heißt',
    'nearOnlyWarn': 'Nichts verlässt dieses Telefon. Mit ausgeschaltetem Bluetooth '
        'gibt es überhaupt keinen Weg hinaus: was du schreibst, bleibt liegen und '
        'geht raus, sobald du einen der beiden Schalter wieder umlegst. Anhänge '
        'gehen gar nicht, die brauchen den Speicherserver.',
    'nearOnlyWarnRadio': 'Kein Server wird angesprochen. Nachrichten gehen direkt '
        'an Kontakte in Bluetooth-Reichweite; alles andere bleibt liegen, bis du '
        'das hier wieder ausschaltest. Das erreicht nur bestätigte Kontakte — wen '
        'du jetzt hinzufügst, bleibt bis dahin eine ausstehende Anfrage, denn die '
        'Anfrage braucht den Relay. Anhänge gehen so oder so nicht, die brauchen '
        'den Speicherserver.',
    'nearOnlyNoAttach': 'Nicht solange „nur in der Nähe“ an ist — ein Anhang braucht den Speicherserver.',
    'nearOnlyWaiting': 'Nur in der Nähe · Nachrichten warten',

    // ---- Der Funk selbst ----
    'nearby': 'In der Nähe',
    'autoScroll': 'Neuen Nachrichten folgen',
    'autoScrollSub': 'Springt zur neuesten Nachricht. Nicht, waehrend du weiter oben liest.',
    'addContact': 'Kontakt hinzufuegen',
    'removeContact': 'Kontakt entfernen',
    'removeAsk': 'Diesen Kontakt und die ganze Unterhaltung entfernen? Das laesst sich nicht rueckgaengig machen.',
    'removeDo': 'ENTFERNEN',
    'nearbyUse': 'Bluetooth benutzen',
    'nearbyUseSub':
        'Erreicht Kontakte in Reichweite direkt, wenn der Relay nicht geht.',
    'nearbyTooOld': 'Braucht Android 12. Darunter hält Android eine '
        'Bluetooth-Suche für eine Standortbestimmung und verlangt den '
        'Standortzugriff — und das ist die eine Berechtigung, die BitDM nicht '
        'abfragt.',
    'nearbyNoHardware': 'Dieses Telefon hat kein Bluetooth LE.',
    'nearbyBtOff': 'Bluetooth ist ausgeschaltet.',
    'nearbyNoPerm': 'BitDM darf Bluetooth noch nicht benutzen.',
    'nearbyAllow': 'Erlauben',
    'nearbyBlocked': 'Abgelehnt, und Android fragt nicht mehr. Das lässt sich '
        'nur noch in den Systemeinstellungen ändern.',
    'nearbyOpenSettings': 'Einstellungen öffnen',
    'nearbyCost': 'Kostet Akku. Wer in Reichweite ist, sieht, dass da ein Gerät '
        'funkt — aber nur wer dich als Kontakt hat, erkennt, dass du es bist.',
    'nearbyNeedsBoth': 'Schalte das hier mit ein, sonst warten Nachrichten nur.',

    // ---- Das Zeichen an einer Nachricht ----
    'viaNearby': 'Direkt',
    'viaNearbyTitle': 'Direkt übertragen',
    'viaNearbyWhat': 'Diese Nachricht ging von Telefon zu Telefon über '
        'Bluetooth. Kein Server war beteiligt — auch keiner, der gesehen '
        'hätte, dass ihr überhaupt miteinander geschrieben habt.',

    // ---- Anwesenheit je Kontakt ----
    'presence': 'Anwesenheit zeigen',
    'presenceSub': 'Aus: dieser Kontakt findet dich nicht über Bluetooth, und '
        'du ihn nicht. Nachrichten nehmen dann immer den Relay.',

    'hintShot': 'Screenshot-Schutz aktiv', 'hintEnc': 'Ende-zu-Ende verschlüsselt', 'hintEph': 'Nachrichten löschen sich nach ',

    // ---- Frische Anmeldung, Woerter, Metadaten, Fernloeschung ----
    'confirmTitle': 'Sicher?', 'confirmYes': 'Ja',
    'freshAuthTitle': 'Bestätige, dass du es bist',
    'freshAuthPw': 'Gib dein App-Passwort ein, um fortzufahren.',
    'freshAuthNone': 'Keine deiner Anmeldearten funktioniert auf diesem Gerät.',
    'phraseShow': 'Wiederherstellungswörter zeigen',
    'phraseShowSub': 'Die 12 Wörter, mit denen du deine Identität zurückholst. Fragt vorher nach deiner Anmeldung.',
    'phraseShowWarn': 'Wer diese Wörter sieht, kann du sein. Nicht fotografieren, nirgends eintippen.',
    'phraseShowFailed': 'Die Wörter ließen sich nicht laden.',
    'copiedSecret': 'Kopiert — die Zwischenablage wird in 30 Sekunden geleert',
    'wipeBannerSec': 'Fernlöschung in {s} s — angefordert von deinen Vertrauenskontakten.',
    'wipeCancelAsk': 'Die Fernlöschung abbrechen, die deine Vertrauenskontakte angefordert haben?',
    'wipeChangeAsk': 'Fernlöschung ändern oder ausschalten?',
    'metaAskTitle': 'Metadaten bleiben in der Datei',
    'metaTooBig': 'Diese Datei ist zu groß, um ihre Metadaten (Ort, Kamera, Zeit) zu entfernen. Trotzdem senden?',
    'metaFailed': 'Die Metadaten (Ort, Kamera, Zeit) ließen sich aus dieser Datei nicht entfernen. Trotzdem senden?',
    'metaNotRemoved': 'Nicht gesendet: die Metadaten ließen sich nicht entfernen.',
    'sendAnyway': 'Trotzdem senden',
    'listSentFailed': 'An {n} geschickt, bei {f} gescheitert',
    'phraseInvalid': 'Diese Wörter sind keine gültige Wiederherstellungsphrase.',
    'pushForeign': 'Der Push-Verteiler nannte einen fremden Server. Er wurde ignoriert.',
    'wipeHow': 'So funktioniert es',
    'wipeCode': 'Codewort',
    'wipeCodeNone': 'Kein Codewort gesetzt. Vertrauenskontakte können nur /wipe benutzen.',
    'wipeCodeIsSet': 'Codewort gesetzt. Gespeichert ist nur ein Prüfwert — das Wort selbst lässt sich nicht mehr auslesen.',
    'wipeCodeSet': 'Codewort festlegen',
    'wipeCodeChange': 'Ändern',
    'wipeCodeRemove': 'Entfernen',
    'wipeCodeTitle': 'Codewort für die Fernlöschung',
    'wipeCodeBody': 'Ein Wort oder Satz, mindestens 6 Zeichen. Schreibt dir ein Vertrauenskontakt genau das, zählt es als Bitte um Löschung — die Nachricht erscheint nicht im Chat. Groß- und Kleinschreibung und doppelte Leerzeichen spielen keine Rolle. Sag es deinen Vertrauenskontakten persönlich, nicht über BitDM. Von allen anderen ist es eine ganz normale Nachricht.',
    'wipeCodeHint': 'Codewort',
    'wipeCodeAgain': 'Wiederholen',
    'wipeCodeShort': 'Mindestens 6 Zeichen.',
    'wipeCodeSaved': 'Codewort gespeichert',
    'wipeCodeRemoved': 'Codewort entfernt',
    'wipeCodeAsk': 'Codewort für die Fernlöschung ändern?',
    'wipeCodeRemoveAsk': 'Codewort entfernen? Vertrauenskontakte können dann nur noch /wipe benutzen.',
    'panicPwNoPw': 'Du entsperrst ohne App-Passwort (Fingerabdruck oder Geräte-PIN)? Der Sperrbildschirm zeigt trotzdem den Knopf „App-Passwort“. Dort tippst du das Panik-Wort ein.',
    'panicPwHint': 'Panik-Wort oder -Satz',
    'panicPwAgain': 'Noch einmal',
    'panicPwShort': 'Mindestens 4 Zeichen.',
    'panicPwEdge': 'Bitte ohne Leerzeichen am Anfang oder Ende.',
    'updateAvail': 'BitDM {neu} ist verfügbar. Du kannst aktualisieren, musst aber nicht.',
    'updateSite': 'Zur Webseite',
    'updateReload': 'Neu laden',
    'updateLater': 'Später',
    'updateNotif': 'BitDM {neu} ist verfügbar.',
    'keyArtLabel': 'Schlüsselbild',
    'keyStoreTitle': 'Schlüssel nicht erreichbar',
    'keyStoreLinux': 'Kein Schlüsselbund erreichbar, oder er ist gesperrt. BitDM legt den Schlüssel deiner Identität dort ab und kann ohne ihn nicht öffnen.\n\nGNOME Keyring oder KWallet starten bzw. entsperren, dann erneut versuchen.',
    'keyStoreOther': 'Der Schlüsselspeicher dieses Geräts hat nicht geantwortet. BitDM legt den Schlüssel deiner Identität dort ab und kann ohne ihn nicht öffnen.\n\nGleich noch einmal versuchen. Klappt es dauerhaft nicht, das Gerät neu starten.',
    'keyStoreSafe': 'Es wurde nichts gelöscht und keine neue Identität angelegt. Gibt es auf diesem Gerät eine Identität, ist sie noch da.',
    'keyStoreRetry': 'Erneut versuchen',
    'keyStoreTrying': 'Wird versucht …',
  },
};

/// Ob die Texte vom Telefon sprechen duerfen: nur in der Android-App.
///
/// Im Browser NICHT, auch auf einem Telefon nicht — dort weiss die App nicht,
/// worauf sie laeuft, und "dieses Geraet" stimmt in beiden Faellen.
bool get textAufTelefon =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Was auf Linux, Windows, macOS und im Browser in diesen Texten anders steht:
/// "Geraet" statt "Telefon". Je Text eine Liste von Ersetzungen (alt, neu).
///
/// Gemeldet vom ersten echten Linux-Lauf (17.10.2026): auf einem Rechner
/// stand "The identity on this phone is sealed".
///
/// ERSETZUNGEN UND KEINE ZWEITEN TEXTE, damit niemand einen Text an zwei
/// Stellen pflegen muss. Aendert jemand oben einen Text so, dass ein `alt`
/// darin nicht mehr vorkommt, faellt das im Test auf
/// (test/oberflaeche/geraet_texte_test.dart) — und ebenso ein neuer Text, der
/// "phone" oder "Telefon" sagt, ohne hier oder in der Liste der reinen
/// Android-Texte dort zu stehen.
const Map<String, Map<String, List<(String, String)>>> geraetErsetzungen = {
  'en': {
    'restoreLinkSub': [('your phone', 'your device')],
    'restoreIntro': [('your old phone', 'your old device')],
    'restoreNote': [('the old phone', 'the old device')],
    'phraseSub': [('this phone', 'this device')],
    'lockedSub': [
      ('nowhere on this device', 'nowhere on it'),
      ('on this phone', 'on this device'),
    ],
    'lockedNoFactor': [('on this phone', 'on this device')],
    // Am Rechner gibt es keinen Sicherheitsschluessel (nur 'pw', siehe
    // _faktorGehtHier in main.dart) — verwechselt wird dort das Passwort, mit
    // dem man sich am Geraet anmeldet.
    'pwUnlockHint': [
      ('Not the phone PIN, not the security key PIN.',
          'Not the password or PIN you use to sign in to this device.'),
    ],
    'wipeSub': [('your phone', 'your device')],
    'wipeExplain': [
      ('on this phone', 'on this device'),
      ('A locked phone', 'A locked device'),
    ],
    'wipeAskText': [('their phone', 'their device')],
    'cmd_wipe': [("contact's phone", "contact's device")],
  },
  'de': {
    'restoreLinkSub': [('Telefon verloren', 'Gerät verloren')],
    'restoreIntro': [('dein altes Telefon', 'dein altes Gerät')],
    'restoreNote': [('dem alten Telefon', 'dem alten Gerät')],
    'phraseSub': [('dieses Telefon', 'dieses Gerät')],
    'lockedSub': [
      ('liegt nirgends lesbar auf diesem Gerät', 'liegt hier nirgends lesbar'),
      ('auf diesem Telefon', 'auf diesem Gerät'),
    ],
    'lockedNoFactor': [('auf diesem Telefon', 'auf diesem Gerät')],
    'pwUnlockHint': [
      ('Nicht die Telefon-PIN und nicht die PIN des Sicherheitsschlüssels.',
          'Nicht das Passwort oder die PIN, mit der du dich an diesem Gerät anmeldest.'),
    ],
    'wipeSub': [('Ist dein Telefon weg', 'Ist dein Gerät weg')],
    'wipeExplain': [
      ('auf diesem Telefon', 'auf diesem Gerät'),
      ('Ein gesperrtes Telefon', 'Ein gesperrtes Gerät'),
    ],
    'wipeAskText': [('das Telefon zu löschen', 'das Gerät zu löschen')],
    'cmd_wipe': [('Telefon dieses Kontakts', 'Gerät dieses Kontakts')],
  },
};

/// Der Text [k] in [lang] — fuer die Plattform, auf der die App laeuft, oder
/// fuer die in [telefon] genannte.
String textFuer(String lang, String k, {bool? telefon}) {
  var text = strings[lang]![k] ?? k;
  if (telefon ?? textAufTelefon) return text;
  for (final (alt, neu) in geraetErsetzungen[lang]?[k] ?? const <(String, String)>[]) {
    text = text.replaceAll(alt, neu);
  }
  return text;
}
