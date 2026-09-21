package com.crosstransfer.crosstransfer;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.DocumentsContract;

// Test APK components run in their own UID, without the target APK classpath.
public class FixtureSetup extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra("id");
        Uri tree = DocumentsContract.buildTreeDocumentUri("ct.android.tests.documents", id);
        context.getContentResolver().call(tree, intent.getStringExtra("method"), id, intent.getExtras());
        setResultCode(Activity.RESULT_OK);
    }
}
