import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 80});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/icon/app_icon.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    semanticLabel: 'DDL Killer Logo',
  );
}
