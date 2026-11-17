import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html_unescape/html_unescape.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'attempt_service.dart';

import 'package:firebase_auth/firebase_auth.dart';

class QuizQuestion {
  final String question;
  final String correctAnswer;
  final List<String> choices;

  QuizQuestion({
    required this.question,
    required this.correctAnswer,
    required this.choices,
  });
}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  static const apiUrl =
      'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple';

  final unescape = HtmlUnescape();

  List<QuizQuestion> questions = [];
  List<String?> answers = [];

  int currentIndex = 0;
  bool loading = true;
  String? error;
  DateTime? lastRequest;

  String? roundId;
  String? roundUid;
  AttemptService? attemptService;

  String cloudState = 'notSubmitted';
  String? cloudMessage;
  Map<String, dynamic>? verifiedData;

  bool injectLostAcknowledgement = false;

  bool get submissionUnresolved =>
      cloudState == 'submitting' ||
      cloudState == 'verifying' ||
      cloudState == 'saveUnknown' ||
      cloudState == 'verificationUnavailable';

  int get score {
    int total = 0;
    for (int i = 0; i < answers.length; i++) {
      if (answers[i] == questions[i].correctAnswer) {
        total++;
      }
    }
    return total;
  }

  bool get finished => questions.isNotEmpty && currentIndex >= questions.length;

  @override
  void initState() {
    super.initState();
    loadQuestions();
  }

  Future<void> loadQuestions() async {
    if (submissionUnresolved) return;
    if (loading && lastRequest != null) return;

    final now = DateTime.now();

    if (lastRequest != null &&
        now.difference(lastRequest!).inMilliseconds < 5000) {
      setState(() {
        error = 'Please wait 5 seconds before retrying.';
        loading = false;
      });
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    lastRequest = now;

    try {
      final response = await http
          .get(Uri.parse(apiUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP error: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid JSON structure');
      }

      if (data['response_code'] != 0) {
        throw Exception('API response code: ${data['response_code']}');
      }

      final results = data['results'];

      if (results is! List || results.length != 10) {
        throw const FormatException('Expected exactly 10 questions');
      }

      final loaded = <QuizQuestion>[];

      for (final item in results) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid question object');
        }

        if (item['category'] != 'General Knowledge' ||
            item['difficulty'] != 'easy' ||
            item['type'] != 'multiple') {
          throw const FormatException('Wrong question category or type');
        }

        final rawQuestion = item['question'];
        final rawCorrect = item['correct_answer'];
        final rawIncorrect = item['incorrect_answers'];

        if (rawQuestion is! String ||
            rawCorrect is! String ||
            rawIncorrect is! List ||
            rawIncorrect.length != 3 ||
            rawIncorrect.any((answer) => answer is! String)) {
          throw const FormatException('Incomplete question');
        }

        final question = unescape.convert(rawQuestion).trim();
        final correct = unescape.convert(rawCorrect).trim();

        final incorrect = rawIncorrect
            .map((answer) => unescape.convert(answer as String).trim())
            .toList();

        final choices = [correct, ...incorrect];

        if (question.isEmpty ||
            choices.any((choice) => choice.isEmpty) ||
            choices.toSet().length != 4) {
          throw const FormatException('Empty or duplicate answers');
        }

        choices.shuffle();

        loaded.add(
          QuizQuestion(
            question: question,
            correctAnswer: correct,
            choices: choices,
          ),
        );
      }

      if (!mounted) return;

      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        throw StateError('Please sign in again');
      }

      final newRoundId = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('attempts')
          .doc()
          .id;

      setState(() {
        questions = loaded;
        answers = List<String?>.filled(10, null);
        currentIndex = 0;
        loading = false;

        roundId = newRoundId;
        roundUid = user.uid;
        attemptService = null;
        cloudState = 'notSubmitted';
        cloudMessage = null;
        verifiedData = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        error = 'Could not load quiz: $e';
      });
    }
  }

  void selectAnswer(String answer) {
    if (answers[currentIndex] != null) return;

    setState(() {
      answers[currentIndex] = answer;
    });
  }

  void nextQuestion() {
    if (answers[currentIndex] == null) return;

    setState(() {
      currentIndex++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('General Knowledge Quiz')),
      body: loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading questions...'),
                ],
              ),
            )
          : error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(error!, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: loadQuestions,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : finished
          ? buildResult()
          : buildQuestion(),
    );
  }

  Widget buildQuestion() {
    final question = questions[currentIndex];
    final selected = answers[currentIndex];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: (currentIndex + 1) / 10),
          const SizedBox(height: 24),
          Text(
            'Question ${currentIndex + 1} / 10',
            style: const TextStyle(fontSize: 18, color: Colors.indigo),
          ),
          const SizedBox(height: 12),
          Text(
            question.question,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),

          for (final choice in question.choices)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                onPressed: selected == null ? () => selectAnswer(choice) : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(18),
                  backgroundColor: selected == null
                      ? null
                      : choice == question.correctAnswer
                      ? Colors.green.shade100
                      : choice == selected
                      ? Colors.red.shade100
                      : null,
                ),
                child: Text(choice, style: const TextStyle(fontSize: 16)),
              ),
            ),

          if (selected != null) ...[
            const SizedBox(height: 16),
            Text(
              selected == question.correctAnswer
                  ? 'Correct!'
                  : 'Incorrect! Correct answer: ${question.correctAnswer}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: selected == question.correctAnswer
                    ? Colors.green
                    : Colors.red,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: nextQuestion,
              child: Text(currentIndex == 9 ? 'See Results' : 'Next Question'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> submitScore() async {
    if (!finished || submissionUnresolved || cloudState == 'cloudVerified') {
      return;
    }

    final uid = roundUid;
    final id = roundId;

    if (uid == null ||
        id == null ||
        FirebaseAuth.instance.currentUser?.uid != uid) {
      setState(() {
        cloudState = 'permissionDenied';
        cloudMessage = 'Authentication changed. Sign in again.';
      });
      return;
    }

    final service =
        attemptService ??
        AttemptService(uid: uid, roundId: id, correctCount: score);

    attemptService = service;

    setState(() {
      cloudState = 'submitting';
      cloudMessage = 'Saving to Cloud Firestore...';
    });

    try {
      await service.createOnce();

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid ||
          roundId != id) {
        return;
      }

      if (injectLostAcknowledgement) {
        setState(() {
          cloudState = 'saveUnknown';
          cloudMessage =
              'Injected fault: save acknowledgement hidden. '
              'Use Recover to check the server.';
        });
        return;
      }

      await verifyScore(service, uid, id);
    } on FirebaseException catch (e) {
      if (!mounted || roundId != id) return;

      setState(() {
        cloudState =
            e.code == 'permission-denied' || e.code == 'unauthenticated'
            ? 'permissionDenied'
            : 'saveUnknown';

        cloudMessage =
            'Firestore error: ${e.code}. '
            'Check the server before retrying.';
      });
    } catch (e) {
      if (!mounted || roundId != id) return;

      setState(() {
        cloudState = 'saveUnknown';
        cloudMessage = 'Save outcome unknown: $e';
      });
    }
  }

  Future<void> verifyScore(
    AttemptService service,
    String uid,
    String id,
  ) async {
    if (!mounted || roundId != id) return;

    setState(() {
      cloudState = 'verifying';
      cloudMessage = 'Reading exact attempt from server...';
    });

    try {
      final data = await service.verifyFromServer();

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid ||
          roundId != id) {
        return;
      }

      setState(() {
        verifiedData = data;
        cloudState = 'cloudVerified';
        cloudMessage = 'Cloud Verified! Server data matches.';
      });
    } catch (e) {
      if (!mounted || roundId != id) return;

      setState(() {
        cloudState = 'verificationUnavailable';
        cloudMessage = 'Server verification unavailable: $e';
      });
    }
  }

  Future<void> recoverScore() async {
    if (cloudState != 'saveUnknown' &&
        cloudState != 'verificationUnavailable' &&
        cloudState != 'permissionDenied') {
      return;
    }

    final service = attemptService;
    final uid = roundUid;
    final id = roundId;

    if (service == null || uid == null || id == null) return;

    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      setState(() {
        cloudState = 'permissionDenied';
        cloudMessage = 'Wrong user. Sign in with the original account.';
      });
      return;
    }

    setState(() {
      cloudState = 'verifying';
      cloudMessage = 'Checking the server for this round...';
    });

    try {
      final existing = await service.ref.get(
        const GetOptions(source: Source.server),
      );

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid ||
          roundId != id) {
        return;
      }

      if (existing.exists) {
        await verifyScore(service, uid, id);
        return;
      }

      // No server record exists. Retry with the SAME round ID.
      setState(() {
        cloudState = 'submitting';
        cloudMessage = 'No saved record found. Retrying same round ID...';
      });

      await service.createOnce();

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid ||
          roundId != id) {
        return;
      }

      await verifyScore(service, uid, id);
    } on FirebaseException catch (e) {
      if (!mounted || roundId != id) return;

      setState(() {
        cloudState =
            e.code == 'permission-denied' || e.code == 'unauthenticated'
            ? 'permissionDenied'
            : 'saveUnknown';

        cloudMessage =
            'Recovery unavailable: ${e.code}. '
            'Reconnect and try again.';
      });
    } catch (e) {
      if (!mounted || roundId != id) return;

      setState(() {
        cloudState = 'saveUnknown';
        cloudMessage = 'Recovery could not finish: $e';
      });
    }
  }

  Widget buildResult() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.emoji_events, size: 72, color: Colors.amber),
        const SizedBox(height: 12),
        const Text(
          'Quiz Completed!',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          'Score: $score / 10',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24),
        ),
        const SizedBox(height: 20),
        const Text(
          'Answer Review',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        for (int i = 0; i < questions.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}. ${questions[i].question}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Your answer: ${answers[i]}'),
                  Text('Correct answer: ${questions[i].correctAnswer}'),
                  Text(
                    answers[i] == questions[i].correctAnswer
                        ? 'Correct'
                        : 'Incorrect',
                    style: TextStyle(
                      color: answers[i] == questions[i].correctAnswer
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 20),

        const SizedBox(height: 20),

        Text(
          'Round ID: ${roundId ?? "Not created"}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),

        const SizedBox(height: 16),

        if (cloudState == 'notSubmitted')
          SwitchListTile(
            title: const Text('Test T09: Lost Acknowledgement'),
            subtitle: const Text(
              'Development test: hide the save acknowledgement '
              'after a real Firestore commit.',
            ),
            value: injectLostAcknowledgement,
            onChanged: (value) {
              setState(() {
                injectLostAcknowledgement = value;
              });
            },
          ),

        if (cloudState == 'notSubmitted')
          ElevatedButton.icon(
            onPressed: submitScore,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('Submit Score'),
          ),

        if (cloudState == 'submitting' || cloudState == 'verifying') ...[
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          Text(cloudMessage ?? 'Processing...', textAlign: TextAlign.center),
        ],

        if (cloudState == 'saveUnknown' ||
            cloudState == 'verificationUnavailable' ||
            cloudState == 'permissionDenied') ...[
          const Icon(Icons.warning_amber, color: Colors.orange, size: 42),
          Text(
            cloudMessage ?? 'Cloud operation unresolved.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: recoverScore,
            child: const Text('Recover / Retry'),
          ),
        ],

        if (cloudState == 'cloudVerified') ...[
          const Icon(Icons.cloud_done, color: Colors.green, size: 56),
          const Text(
            'Cloud Verified!',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.green,
              fontWeight: FontWeight.bold,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Saved score: ${verifiedData?['correctCount']} / 10',
            textAlign: TextAlign.center,
          ),
          Text(
            'Server timestamp: ${verifiedData?['submittedAt']}',
            textAlign: TextAlign.center,
          ),
        ],

        const SizedBox(height: 20),

        ElevatedButton(
          onPressed: submissionUnresolved ? null : loadQuestions,
          child: const Text('Replay Quiz'),
        ),
      ],
    );
  }
}
