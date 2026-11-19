import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../camera.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';

/// The phone as the camera for another session (decision 2): what a photo
/// would be for, a large shutter button, and the last photo with where it
/// went. The app shows only this until the camera is stopped.
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final camera = context.watch<Camera>();
    final pairing = camera.pairing;
    if (pairing == null) return const Scaffold();
    final target = camera.target;
    final shot = camera.shot;
    final ready =
        target != null &&
        target.ready &&
        !camera.unreachable &&
        !(shot?.sending ?? false);
    final text = Theme.of(context).textTheme;
    final colours = Theme.of(context).colorScheme;

    Future<void> run(Future<void> Function() work) async {
      try {
        await work();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        actions: [
          TextButton(onPressed: camera.stop, child: const Text('Stop')),
        ],
      ),
      body: SafeArea(
        child: Readable(
          maxWidth: 600,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Photos go to what ${pairing.label} has open.',
                  style: text.bodyMedium?.copyWith(
                    color: colours.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                _TargetCard(target: target, unreachable: camera.unreachable),
                const SizedBox(height: 16),
                Expanded(
                  child: shot == null
                      ? const SizedBox.shrink()
                      : _LastShot(shot: shot, onRetry: camera.send),
                ),
                const SizedBox(height: 16),
                if (canTakePhoto(context))
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(72),
                      textStyle: text.titleMedium,
                    ),
                    onPressed: ready ? () => run(camera.takePhoto) : null,
                    icon: const Icon(Icons.photo_camera_outlined, size: 28),
                    label: const Text('Take photo'),
                  ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: ready ? () => run(camera.choosePhoto) : null,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Choose a photo'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a photo would be for, or why none can be taken.
class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.target, required this.unreachable});

  final CameraTarget? target;
  final bool unreachable;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final target = this.target;
    final Widget content;
    if (unreachable) {
      content = const ListTile(
        leading: Icon(Icons.cloud_off_outlined),
        title: Text("Can't reach the server"),
        subtitle: Text('Trying again.'),
      );
    } else if (target == null) {
      content = const Padding(
        padding: EdgeInsets.all(24),
        child: LinearProgressIndicator(),
      );
    } else if (Camera.notReady(target) case final why?) {
      content = ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(why, style: text.titleMedium),
      );
    } else {
      content = ListTile(
        leading: Icon(switch (target.type) {
          'stock' => Icons.inventory_2_outlined,
          'location' => Icons.place_outlined,
          _ => Icons.category_outlined,
        }),
        title: Text(target.name ?? '', style: text.titleLarge),
        subtitle: Text('The photo of this ${CameraTarget.kind(target.type)}'),
      );
    }
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: content,
      ),
    );
  }
}

/// The last photo, and how sending it went: sending, where it went, or why
/// it didn't, to send again.
class _LastShot extends StatelessWidget {
  const _LastShot({required this.shot, required this.onRetry});

  final CameraShot shot;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    final error = shot.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              shot.bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (shot.sending)
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sending…'),
              SizedBox(height: 4),
              LinearProgressIndicator(),
            ],
          )
        else if (error != null)
          Row(
            children: [
              Expanded(
                child: Text(error, style: TextStyle(color: colours.error)),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Send again'),
              ),
            ],
          )
        else if (shot.sentTo case final to?)
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: colours.primary),
              const SizedBox(width: 8),
              Expanded(child: Text('Added to ${to.name ?? 'it'}')),
            ],
          ),
      ],
    );
  }
}
