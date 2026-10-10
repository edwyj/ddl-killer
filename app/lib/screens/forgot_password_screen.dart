import 'package:flutter/material.dart';

import 'email_account_screen.dart';

class ForgotPasswordScreen extends StatelessWidget {
  const ForgotPasswordScreen({super.key});
  @override
  Widget build(BuildContext context) => const EmailAccountScreen(reset: true);
}
