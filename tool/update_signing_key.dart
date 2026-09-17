import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<int> main(List<String> args) async {
  final secretsDir = Directory(
    _valueAfter(args, '--secrets-dir') ?? '.secrets',
  );
  final privateFile = File(
    '${secretsDir.path}${Platform.pathSeparator}'
    'windows_update_signing_private_key',
  );
  final publicFile = File(
    '${secretsDir.path}${Platform.pathSeparator}'
    'windows_update_signing_public_key',
  );

  if (privateFile.existsSync() || publicFile.existsSync()) {
    stderr.writeln(
      'Refusing to overwrite an existing Windows update signing key.\n'
      'Remove both files deliberately if you intend to rotate the key.',
    );
    return 1;
  }

  secretsDir.createSync(recursive: true);
  final keyPair = await Ed25519().newKeyPair();
  final privateBytes = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();
  privateFile.writeAsStringSync('${base64Encode(privateBytes)}\n', flush: true);
  publicFile.writeAsStringSync(
    '${base64Encode(publicKey.bytes)}\n',
    flush: true,
  );

  stdout.writeln('Windows update signing key created.');
  stdout.writeln('  private: ${privateFile.path} (publisher only)');
  stdout.writeln('  public : ${publicFile.path} (embedded in app)');
  return 0;
}

String? _valueAfter(List<String> args, String option) {
  final index = args.indexOf(option);
  if (index < 0) return null;
  if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw ArgumentError('$option requires a value');
  }
  return args[index + 1];
}
