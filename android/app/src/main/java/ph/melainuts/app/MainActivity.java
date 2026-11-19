package ph.melainuts.app;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.provider.Settings;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    // lib/core/services/nfc_card_reader.dart (openNfcSettings): the "Turn on NFC"
    // button on the POS loyalty card screen.
    private static final String NFC_CHANNEL = "ph.melainuts.app/nfc";

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), NFC_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if ("openNfcSettings".equals(call.method)) {
                        result.success(openSettings(Settings.ACTION_NFC_SETTINGS)
                                || openSettings(Settings.ACTION_WIRELESS_SETTINGS)
                                || openSettings(Settings.ACTION_SETTINGS));
                    } else {
                        result.notImplemented();
                    }
                });
    }

    private boolean openSettings(String action) {
        try {
            Intent intent = new Intent(action);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException e) {
            return false;
        }
    }
}
