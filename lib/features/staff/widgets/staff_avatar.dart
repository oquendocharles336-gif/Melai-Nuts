import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../data/models/staff_models.dart';
import '../../../data/repositories/staff_repository.dart';

/// A staff member's picture, or their initials when they have none or it
/// cannot be loaded.
class StaffAvatar extends StatefulWidget {
  final StaffProfile profile;
  final double size;

  const StaffAvatar({super.key, required this.profile, this.size = 48});

  @override
  State<StaffAvatar> createState() => _StaffAvatarState();
}

class _StaffAvatarState extends State<StaffAvatar> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(StaffAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.profileImage != widget.profile.profileImage) _resolve();
  }

  Future<void> _resolve() async {
    final path = widget.profile.profileImage;
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _url = null);
      return;
    }
    final url = await StaffRepository.instance.profilePhotoUrl(path);
    if (mounted && widget.profile.profileImage == path) setState(() => _url = url);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final initials = Center(
      child: Text(
        widget.profile.initials,
        style: AppTextStyles.titleMd.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
        ),
      ),
    );
    final url = _url;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.roleStaff, Color(0xFF14B8A6)],
        ),
        border: Border.all(color: Colors.white, width: size > 60 ? 3 : 1.5),
        boxShadow: AppShadows.sm,
      ),
      child: url == null
          ? initials
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => initials,
              semanticLabel: 'Profile picture',
            ),
    );
  }
}

/// Lets the signed-in staff member choose, replace or remove their picture.
Future<void> changeStaffPhoto(BuildContext context) async {
  final store = StaffStore.instance;
  final hasPhoto = (store.profile?.profileImage ?? '').isNotEmpty;
  final messenger = ScaffoldMessenger.of(context);

  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    backgroundColor: AppColors.ivory,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppSpacing.radiusLg + 4)),
    ),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Profile picture', style: AppTextStyles.headlineSm),
          const SizedBox(height: AppSpacing.xs),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.roleStaff),
            title: Text(hasPhoto ? 'Choose a new picture' : 'Choose a picture', style: AppTextStyles.labelLg),
            onTap: () => Navigator.of(sheet).pop('pick'),
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
              title: Text('Remove picture', style: AppTextStyles.labelLg.copyWith(color: AppColors.error)),
              onTap: () => Navigator.of(sheet).pop('remove'),
            ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    ),
  );

  try {
    if (choice == 'remove') {
      await store.removeProfilePhoto();
      messenger.showSnackBar(const SnackBar(content: Text('Profile picture removed.')));
    } else if (choice == 'pick') {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 82,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > StaffRepository.maxProfilePhotoBytes) {
        messenger.showSnackBar(const SnackBar(content: Text('That picture is too large. Please choose another one.')));
        return;
      }
      await store.setProfilePhoto(bytes, contentType: _imageType(file.mimeType, file.name));
      messenger.showSnackBar(const SnackBar(content: Text('Profile picture updated.')));
    }
  } catch (e, stack) {
    AppErrors.report(e, stack, 'staff_avatar:changeStaffPhoto');
    messenger.showSnackBar(SnackBar(content: Text('Could not save your picture. ${AppErrors.from(e).message}')));
  }
}

String _imageType(String? mimeType, String name) {
  if (mimeType != null && mimeType.startsWith('image/')) return mimeType;
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}
