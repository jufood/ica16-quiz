
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class SavedAttemptPage extends StatefulWidget {
  const SavedAttemptPage({super.key});

  @override
  State<SavedAttemptPage> createState() => _SavedAttemptPageState();
}

class _SavedAttemptPageState extends State<SavedAttemptPage> {
  final idController = TextEditingController();
  bool loading = false;
  String? error;
  Map<String, dynamic>? result;

  Future<void> retrieveAttempt() async {
    final id = idController.text.trim();
    final user = FirebaseAuth.instance.currentUser;

    if (id.isEmpty || id.contains('/')) {
      setState(() {
        error = 'Enter a valid Round ID.';
      });
      return;
    }

    if (user == null) {
      setState(() {
        error = 'Please sign in again.';
      });
      return;
    }

    final uid = user.uid;

    setState(() {
      loading = true;
      error = null;
      result = null;
    });

    try {
      final ref = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('attempts')
          .doc(id);

      final snapshot = await ref.get(
        const GetOptions(source: Source.server),
      );

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != uid) {
        return;
      }

      if (!snapshot.exists ||
          snapshot.metadata.isFromCache ||
          snapshot.metadata.hasPendingWrites) {
        throw StateError('No verified server document found.');
      }

      final data = snapshot.data()!;

      final valid = data.length == 6 &&
          data['schemaVersion'] == 1 &&
          data['variant'] == 'A' &&
          data['categoryId'] == 9 &&
          data['questionCount'] == 10 &&
          data['correctCount'] is int &&
          (data['correctCount'] as int) >= 0 &&
          (data['correctCount'] as int) <= 10 &&
          data['submittedAt'] is Timestamp;

      if (!valid) {
        throw StateError('Saved document has invalid fields.');
      }

      setState(() {
        result = data;
      });
    } catch (e) {
      if (!mounted || FirebaseAuth.instance.currentUser?.uid != uid) {
        return;
      }
      setState(() {
        error = 'Server retrieval failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    idController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved Attempt')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Retrieve a Completed Round',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Enter a previous Round ID to retrieve '
              'the exact attempt from Cloud Firestore.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: idController,
              enabled: !loading,
              decoration: const InputDecoration(
                labelText: 'Round ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: loading ? null : retrieveAttempt,
              child: loading
                  ? const CircularProgressIndicator()
                  : const Text('Retrieve from Server'),
            ),
            if (error != null) ...[
              const SizedBox(height: 20),
              Text(
                error!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 32),
              const Icon(
                Icons.cloud_done,
                size: 64,
                color: Colors.green,
              ),
              const Text(
                'Cloud Verified!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text('Round ID: ${idController.text.trim()}'),
              Text('Score: ${result!['correctCount']} / 10'),
              Text('Variant: ${result!['variant']}'),
              Text('Category ID: ${result!['categoryId']}'),
              Text('Question Count: ${result!['questionCount']}'),
              Text('Schema Version: ${result!['schemaVersion']}'),
              Text('Submitted At: ${result!['submittedAt']}'),
              const SizedBox(height: 12),
              const Text(
                'Verified using Source.server, not the SDK cache.',
                style: TextStyle(color: Colors.green),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
