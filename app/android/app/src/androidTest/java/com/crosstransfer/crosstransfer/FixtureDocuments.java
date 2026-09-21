package com.crosstransfer.crosstransfer;

import android.content.Intent;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;

public class FixtureDocuments extends DocumentsProvider {
    private static final String[] COLUMNS = {Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE};
    private File Root() { File root = new File(getContext().getFilesDir(), "documents"); root.mkdirs(); return root; }
    private File FileFor(String id) {
        try {
            File root = Root().getCanonicalFile();
            File file = new File(root, id).getCanonicalFile();
            if (!file.equals(root) && !file.getPath().startsWith(root.getPath() + File.separator)) throw new SecurityException(id);
            return file;
        } catch (IOException e) { throw new IllegalArgumentException(e); }
    }
    private String Id(File file) {
        try { return file.getCanonicalPath().substring(Root().getCanonicalPath().length() + 1); }
        catch (IOException e) { throw new IllegalArgumentException(e); }
    }
    private void Add(MatrixCursor cursor, File file) {
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : cursor.getColumnNames()) {
            switch (column) {
                case Document.COLUMN_DOCUMENT_ID: row.add(Id(file)); break;
                case Document.COLUMN_DISPLAY_NAME: row.add(file.getName()); break;
                case Document.COLUMN_MIME_TYPE: row.add(file.isDirectory() ? Document.MIME_TYPE_DIR : "application/octet-stream"); break;
                case Document.COLUMN_FLAGS: row.add(Document.FLAG_SUPPORTS_WRITE | Document.FLAG_SUPPORTS_DELETE | (file.isDirectory() ? Document.FLAG_DIR_SUPPORTS_CREATE : 0)); break;
                case Document.COLUMN_SIZE: row.add(file.length()); break;
                default: row.add(null);
            }
        }
    }
    private void Write(File file, byte[] bytes) throws IOException {
        file.getParentFile().mkdirs();
        try (FileOutputStream output = new FileOutputStream(file)) { output.write(bytes); }
    }
    private void Delete(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) Delete(child);
        file.delete();
    }
    @Override public boolean onCreate() { return true; }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        if (!method.equals("ct.setup") && !method.equals("ct.cleanup")) return super.call(method, arg, extras);
        String id = UUID.fromString(arg).toString();
        long token = Binder.clearCallingIdentity();
        try {
            if (method.equals("ct.cleanup")) { Delete(FileFor(id)); return new Bundle(); }
            File source = FileFor(id + "/输入");
            new File(source, "子目录/empty").mkdirs();
            byte[] payload = new byte[130001];
            for (int i = 0; i < payload.length; i++) payload[i] = (byte) (i % 251);
            Write(new File(source, "子目录/中文.bin"), payload);
            Write(new File(source, "zero.bin"), new byte[0]);
            for (String name : new String[]{"one", "two"}) Write(FileFor(id + "/" + name + "/same.bin"), name.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            for (String document : new String[]{id, id + "/输入"}) {
                Uri tree = DocumentsContract.buildTreeDocumentUri("ct.android.tests.documents", document);
                getContext().grantUriPermission(extras.getString("package"), tree, Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            }
            return new Bundle();
        } catch (IOException e) { throw new IllegalStateException(e); }
        finally { Binder.restoreCallingIdentity(token); }
    }
    @Override public Cursor queryRoots(String[] projection) { return new MatrixCursor(projection != null ? projection : new String[]{"root_id"}); }
    @Override public Cursor queryDocument(String documentId, String[] projection) {
        MatrixCursor cursor = new MatrixCursor(projection != null ? projection : COLUMNS);
        Add(cursor, FileFor(documentId)); return cursor;
    }
    @Override public Cursor queryChildDocuments(String parentDocumentId, String[] projection, String sortOrder) {
        MatrixCursor cursor = new MatrixCursor(projection != null ? projection : COLUMNS);
        File[] children = FileFor(parentDocumentId).listFiles();
        if (children != null) for (File child : children) Add(cursor, child);
        return cursor;
    }
    @Override public boolean isChildDocument(String parentDocumentId, String documentId) { return FileFor(documentId).getPath().startsWith(FileFor(parentDocumentId).getPath() + File.separator); }
    @Override public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal) throws FileNotFoundException { return ParcelFileDescriptor.open(FileFor(documentId), ParcelFileDescriptor.parseMode(mode)); }
    @Override public String createDocument(String parentDocumentId, String mimeType, String displayName) throws FileNotFoundException {
        if (displayName.isEmpty() || displayName.contains("/") || displayName.equals("..")) throw new SecurityException(displayName);
        File file = new File(FileFor(parentDocumentId), displayName);
        try {
            boolean created = mimeType.equals(Document.MIME_TYPE_DIR) ? file.mkdir() : file.createNewFile();
            if (!created) throw new FileNotFoundException(file.toString());
        } catch (IOException e) { throw new FileNotFoundException(e.toString()); }
        return Id(file);
    }
    @Override public void deleteDocument(String documentId) { Delete(FileFor(documentId)); }
}
