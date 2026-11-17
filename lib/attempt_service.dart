
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AttemptCollision implements Exception {
  @override
  String toString() => 'Round ID collision: different score data';
}

class AttemptService {
  final String uid;
  final String roundId;
  final int correctCount;

  AttemptService({
    required this.uid,
    required this.roundId,
    required this.correctCount,
  });

  DocumentReference<Map<String, dynamic>> get ref =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('attempts')
          .doc(roundId);

  void checkUser() {
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      throw FirebaseAuthException(code: 'unauthenticated');
    }
  }

  Map<String, dynamic> get fixedFields => {
        'schemaVersion': 1,
        'variant': 'A',
        'categoryId': 9,
        'questionCount': 10,
        'correctCount': correctCount,
      };

  bool matches(Map<String, dynamic>? data) {
    if (data == null || data.length != 6) return false;

    for (final field in fixedFields.entries) {
      if (data[field.key] != field.value) return false;
    }

    return data['submittedAt'] is Timestamp;
  }

  Future<void> createOnce() async {
    checkUser();

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final existing = await transaction.get(ref);

      if (existing.exists) {
        if (!matches(existing.data())) {
          throw AttemptCollision();
        }
        return;
      }

      transaction.set(ref, {
        ...fixedFields,
        'submittedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<Map<String, dynamic>> verifyFromServer() async {
    checkUser();

    final snapshot = await ref.get(
      const GetOptions(source: Source.server),
    );

    checkUser();

    if (!snapshot.exists ||
        snapshot.metadata.isFromCache ||
        snapshot.metadata.hasPendingWrites ||
        !matches(snapshot.data())) {
      throw StateError('Server verification did not match');
    }

    return snapshot.data()!;
  }
}
