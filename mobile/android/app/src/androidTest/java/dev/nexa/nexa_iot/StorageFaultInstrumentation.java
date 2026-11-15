package dev.nexa.nexa_iot;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.res.XmlResourceParser;
import org.xmlpull.v1.XmlPullParser;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import android.os.Bundle;

import com.it_nomads.fluttersecurestorage.FlutterSecureStorage;
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig;
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback;

import java.security.KeyStore;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Test APK riêng kiểm mất khóa trên namespace tổng hợp; không đăng ký hook trong app. */
public final class StorageFaultInstrumentation extends Instrumentation {
    private final String namespace = "nexa_key_fault_poc_v1_" + UUID.randomUUID().toString().replace("-", "");
    private final String controlNamespace = namespace + "_control";
    private boolean ownsNamespaces;
    private boolean inspectProductionStorage;
    private String stage = "preconditions";
    private static final String MARKER = "synthetic-native-key-loss-not-a-credential";

    /** Bắt đầu worker instrumentation; không nhận selector/key/namespace từ tham số bên ngoài.
     * Input
     * Param: arguments — container framework; chỉ chuyển cho base runner, không dùng làm authority. */
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        inspectProductionStorage = arguments != null && "true".equals(arguments.getString("inspectProductionStorage"));
        start();
    }

    /** Chạy invariant native và dọn đúng tài nguyên đã tạo; chỉ trả mã/boolean, không lỗi gốc. */
    @Override
    public void onStart() {
        boolean passed = false;
        boolean cleaned = false;
        try {
            if (inspectProductionStorage) runProductionStorageInspection();
            else runKeyLossProbe();
            passed = true;
        } catch (Exception failure) {
            // Exception nền tảng có thể chứa dữ liệu; báo mã cố định thay vì serialize nguyên nhân.
            passed = false;
        } finally {
            try {
                cleanupOwnedNamespaces();
                cleaned = true;
            } catch (Exception failure) {
                cleaned = false;
            }
        }
        Bundle result = new Bundle();
        result.putString("probe", inspectProductionStorage
                ? (passed ? "NATIVE_STORAGE_INSPECTION_PASS" : "NATIVE_STORAGE_INSPECTION_FAILED")
                : (passed ? "NATIVE_KEY_LOSS_REJECTED" : "NATIVE_KEY_LOSS_FAILED"));
        result.putString("stage", stage);
        result.putBoolean("cleanup", cleaned);
        finish(passed && cleaned ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }

    /** Đọc marker của adapter PoC đã ghi từ Dart, kiểm file plaintext và policy backup của APK thật.
     * Chỉ đọc production namespace khi giá trị đúng marker test đã biết, không xuất token/file/key ra result.
     * Side effects: plugin nạp config/keystore hiện hữu sau precondition; không xóa credential. Dart stage kế tiếp dọn marker. */
    private void runProductionStorageInspection() throws Exception {
        Context context = getTargetContext();
        require(context.getPackageName().equals("dev.nexa.nexa_iot"), "TARGET_MISMATCH");
        stage = "owned_adapter_marker";
        final String marker = "synthetic-adapter-session-not-a-real-credential";
        for (String name : preferenceNames("nexa_auth_session_v1")) {
            File file = new File(new File(context.getApplicationInfo().dataDir, "shared_prefs"), name + ".xml");
            require(file.isFile() && file.length() > 0, "EXISTING_ADAPTER_STORE_REQUIRED");
        }
        require(androidKeyStore().containsAlias(alias("nexa_auth_session_v1")), "EXISTING_ADAPTER_ALIAS_REQUIRED");
        FlutterSecureStorage store = initializedStore("nexa_auth_session_v1");
        CallbackResult<String> read = new CallbackResult<>();
        store.read(store.addPrefixToKey("session_token"), read);
        read.requireSuccess();
        require(marker.equals(read.value), "OWNED_ADAPTER_MARKER_REQUIRED");
        stage = "compiled_backup_policy";
        ApplicationInfo info = context.getApplicationInfo();
        require((info.flags & ApplicationInfo.FLAG_ALLOW_BACKUP) == 0, "BACKUP_MUST_BE_DISABLED");
        verifyCompiledBackupReferences();
        verifyBackupResource("auth_backup_rules", 1);
        verifyBackupResource("auth_data_extraction_rules", 2);
        stage = "private_preferences_inspection";
        File directory = new File(info.dataDir, "shared_prefs");
        File[] files = directory.listFiles();
        require(files != null && files.length > 0 && files.length <= 64, "PREFERENCE_SCAN_SCOPE_INVALID");
        int bytesRead = 0;
        // Chỉ preferences thuộc đúng target UID, không cache/build/environment hoặc app khác.
        for (File file : files) {
            long length = file.length();
            require(file.isFile() && file.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile())
                    && length >= 0 && length <= 524288 && bytesRead + length <= 1048576, "PREFERENCE_SCAN_SCOPE_INVALID");
            byte[] bytes;
            try (FileInputStream input = new FileInputStream(file)) {
                bytes = new byte[(int) length];
                int offset = 0;
                while (offset < bytes.length) {
                    int count = input.read(bytes, offset, bytes.length - offset);
                    require(count > 0, "PREFERENCE_SCAN_TRUNCATED");
                    offset += count;
                }
                require(input.read() == -1, "PREFERENCE_SCAN_CHANGED");
            }
            bytesRead += bytes.length;
            require(bytesRead <= 1048576, "PREFERENCE_SCAN_BUDGET_EXCEEDED");
            String content = new String(bytes, StandardCharsets.UTF_8);
            require(!containsPrivateMarker(content, marker)
                    && !containsPrivateMarker(content, "synthetic-adapter-proof-not-a-real-installation"),
                    "PLAINTEXT_MARKER_FOUND");
            java.util.Arrays.fill(bytes, (byte) 0);
        }
        require(bytesRead > 0, "PREFERENCE_SCAN_EMPTY");
        require(containsPrivateMarker(marker, marker)
                && containsPrivateMarker(android.util.Base64.encodeToString(marker.getBytes(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP), marker),
                "SCAN_POSITIVE_CONTROL_FAILED");
        stage = "verified";
    }

    /** Tìm canary nguyên văn hoặc Base64 trong bytes đã giải mã UTF8, không xuất dữ liệu được scan.
     * Input
     * Param: content — nội dung preferences đã giới hạn byte và thuộc đúng target UID.
     * Param: marker — marker synthetic của adapter PoC, không credential người dùng.
     * Output: true nếu dữ liệu có plaintext hoặc chỉ che bằng Base64. */
    private boolean containsPrivateMarker(String content, String marker) {
        return content.contains(marker) || content.contains(android.util.Base64.encodeToString(
                marker.getBytes(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP));
    }

    /** Kiểm application node của manifest binary trỏ đúng hai backup resources đã đóng gói.
     * Không suy policy runtime từ resource có mặt nhưng không được manifest sử dụng. */
    private void verifyCompiledBackupReferences() throws Exception {
        Context context = getTargetContext();
        String androidNamespace = "http://schemas.android.com/apk/res/android";
        boolean found = false;
        try (XmlResourceParser parser = context.getAssets().openXmlResourceParser("AndroidManifest.xml")) {
            for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
                if (event == XmlPullParser.START_TAG && "application".equals(parser.getName())) {
                    require(!found, "DUPLICATE_MANIFEST_APPLICATION");
                    found = true;
                    int full = context.getResources().getIdentifier("auth_backup_rules", "xml", context.getPackageName());
                    int extraction = context.getResources().getIdentifier("auth_data_extraction_rules", "xml", context.getPackageName());
                    require(full != 0 && extraction != 0
                            && parser.getAttributeResourceValue(androidNamespace, "fullBackupContent", 0) == full
                            && parser.getAttributeResourceValue(androidNamespace, "dataExtractionRules", 0) == extraction,
                            "COMPILED_BACKUP_REFERENCE_INVALID");
                }
            }
        }
        require(found, "MANIFEST_APPLICATION_MISSING");
    }

    /** Kiểm exclude nằm đúng từng parent của XML backup đã đóng gói.
     * Input
     * Param: name — resource literal của target APK, không path nhận từ adb.
     * Param: expected —1 cho full backup,2 cho cloud-backup và device-transfer độc lập.
     * Errors: thiếu parent, duplicate hoặc exclude sai vị trí khiến probe fail. */
    private void verifyBackupResource(String name, int expected) throws Exception {
        Context context = getTargetContext();
        int resource = context.getResources().getIdentifier(name, "xml", context.getPackageName());
        require(resource != 0, "BACKUP_RESOURCE_MISSING");
        int full = 0;
        int cloud = 0;
        int device = 0;
        String root = null;
        String section = null;
        try (XmlResourceParser parser = context.getResources().getXml(resource)) {
            for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
                if (event == XmlPullParser.START_TAG && parser.getDepth() == 1) root = parser.getName();
                if (event == XmlPullParser.START_TAG && parser.getDepth() == 2) section = parser.getName();
                if (event == XmlPullParser.START_TAG && "exclude".equals(parser.getName())
                        && "sharedpref".equals(parser.getAttributeValue(null, "domain"))
                        && ".".equals(parser.getAttributeValue(null, "path"))) {
                    if (parser.getDepth() == 2 && "full-backup-content".equals(root)) full++;
                    else if (parser.getDepth() == 3 && "data-extraction-rules".equals(root)
                            && "cloud-backup".equals(section)) cloud++;
                    else if (parser.getDepth() == 3 && "data-extraction-rules".equals(root)
                            && "device-transfer".equals(section)) device++;
                    else throw new IllegalStateException("BACKUP_EXCLUSION_PARENT_INVALID");
                }
                if (event == XmlPullParser.END_TAG && parser.getDepth() == 2) section = null;
            }
        }
        require(expected == 1 ? full == 1 && cloud == 0 && device == 0
                : expected == 2 && full == 0 && cloud == 1 && device == 1,
                "BACKUP_PREFERENCE_EXCLUSION_INVALID");
    }

    /** Tạo dữ liệu tổng hợp, làm mất đúng alias rồi yêu cầu fresh instance báo lỗi và giữ ciphertext. */
    private void runKeyLossProbe() throws Exception {
        Context context = getTargetContext();
        require(context.getPackageName().equals("dev.nexa.nexa_iot"), "TARGET_MISMATCH");
        assertVacant(namespace);
        assertVacant(controlNamespace);
        // Ownership chỉ có sau khi cả hai namespace/alias đều được xác nhận chưa tồn tại.
        ownsNamespaces = true;
        stage = "baseline";
        FlutterSecureStorage store = initializedStore(namespace);
        FlutterSecureStorage control = initializedStore(controlNamespace);
        writeMarker(store);
        writeMarker(control);
        require(MARKER.equals(readMarker(store)), "BASELINE_READ_FAILED");
        require(MARKER.equals(readMarker(control)), "CONTROL_READ_FAILED");
        SharedPreferences data = context.getSharedPreferences(namespace, Context.MODE_PRIVATE);
        require(data.edit().commit(), "FLUSH_FAILED");
        Map<String, ?> before = new HashMap<>(data.getAll());
        require(!before.isEmpty(), "EMPTY_BASELINE");
        stage = "key_loss";
        KeyStore keys = androidKeyStore();
        require(keys.containsAlias(alias(namespace)), "OWNED_ALIAS_MISSING");
        keys.deleteEntry(alias(namespace));
        require(!keys.containsAlias(alias(namespace)), "FAULT_NOT_APPLIED");

        // Instance cũ giữ AES trong RAM; fresh instance mới thực sự kiểm unwrap sau mất RSA key.
        stage = "fresh_instance_rejects";
        FlutterSecureStorage fresh = new FlutterSecureStorage(context);
        CallbackResult<Void> failedInit = new CallbackResult<>();
        fresh.initialize(config(namespace), failedInit);
        failedInit.awaitCompletion();
        require(failedInit.failed, "KEY_LOSS_SILENTLY_ACCEPTED");
        stage = "preserve_data_and_sibling";
        require(before.equals(data.getAll()), "RESET_CHANGED_ENCRYPTED_DATA");
        require(MARKER.equals(readMarker(initializedStore(controlNamespace))), "SIBLING_NAMESPACE_DAMAGED");
        stage = "verified";
    }

    /** Kiểm ba preference stores và alias đúng namespace nội bộ chưa có dữ liệu trước khi nhận ownership.
     * Input
     * Param: name — namespace ngẫu nhiên do test tự tạo, không nhận từ adb arguments. */
    private void assertVacant(String name) throws Exception {
        require(!androidKeyStore().containsAlias(alias(name)), "ALIAS_ALREADY_EXISTS");
        for (String preferences : preferenceNames(name)) {
            require(getTargetContext().getSharedPreferences(preferences, Context.MODE_PRIVATE).getAll().isEmpty(), "STORE_ALREADY_EXISTS");
        }
    }

    /** Tạo plugin instance với cùng cipher/reset policy của adapter, chỉ đổi namespace PoC.
     * Input
     * Param: name — namespace test đã xác nhận ownership.
     * Output: plugin đã initialize thành công; lỗi cố định nếu callback thất bại. */
    private FlutterSecureStorage initializedStore(String name) throws Exception {
        FlutterSecureStorage store = new FlutterSecureStorage(getTargetContext());
        CallbackResult<Void> result = new CallbackResult<>();
        store.initialize(config(name), result);
        result.requireSuccess();
        return store;
    }

    /** Cấu hình plugin11.2.0: RSA-OAEP/AES-GCM mặc định, reset=false, không biometric.
     * Input
     * Param: name — namespace chỉ dùng cho PoC.
     * Output: config native đọc cùng wire options mà adapter Dart gửi. */
    private FlutterSecureStorageConfig config(String name) {
        Map<String, Object> options = new HashMap<>();
        options.put("storageNamespace", name);
        options.put("resetOnError", "false");
        return new FlutterSecureStorageConfig(options);
    }

    /** Ghi marker không hoạt động qua plugin, chờ ACK mà không log giá trị.
     * Input
     * Param: store — instance thuộc namespace PoC. */
    private void writeMarker(FlutterSecureStorage store) throws Exception {
        CallbackResult<Void> result = new CallbackResult<>();
        store.write(store.addPrefixToKey("probe"), MARKER, result);
        result.requireSuccess();
    }

    /** Đọc marker trong RAM để so sánh, không serialize callback result.
     * Input
     * Param: store — instance thuộc namespace PoC.
     * Output: marker tổng hợp, không credential tài khoản thật. */
    private String readMarker(FlutterSecureStorage store) throws Exception {
        CallbackResult<String> result = new CallbackResult<>();
        store.read(store.addPrefixToKey("probe"), result);
        result.requireSuccess();
        return result.value;
    }

    /** Dọn alias và dữ liệu chỉ khi lượt sống đã xác nhận ownership; không quét/xóa namespace khác. */
    private void cleanupOwnedNamespaces() throws Exception {
        if (!ownsNamespaces) return;
        KeyStore keys = androidKeyStore();
        for (String name : new String[] {namespace, controlNamespace}) {
            keys.deleteEntry(alias(name));
            require(!keys.containsAlias(alias(name)), "OWNED_ALIAS_CLEANUP_FAILED");
            for (String preferences : preferenceNames(name)) {
                SharedPreferences store = getTargetContext().getSharedPreferences(preferences, Context.MODE_PRIVATE);
                require(store.edit().clear().commit(), "OWNED_STORE_CLEANUP_FAILED");
                require(store.getAll().isEmpty(), "OWNED_STORE_NOT_EMPTY");
            }
        }
    }

    /** Tên stores theo source plugin đúng tag11.2.0; không lấy path/selector từ filesystem hoặc journal.
     * Input
     * Param: name — namespace nội bộ.
     * Output: đúng ba stores data/config/wrapped-key của namespace đó. */
    private String[] preferenceNames(String name) {
        return new String[] {name, "FlutterSecureStorageConfiguration:" + name, "FlutterSecureKeyStorage:" + name};
    }

    /** Suy alias RSA theo source KeyCipherImplementationRSAOAEP11.2.0 cho target UID hiện tại.
     * Input
     * Param: name — namespace test đã tạo trong process này.
     * Output: duy nhất alias test, không alias mặc định/auth production. */
    private String alias(String name) {
        return getTargetContext().getPackageName() + ".FlutterSecureStoragePluginKeyOAEP." + name;
    }

    /** Mở AndroidKeyStore của target UID để chỉ thao tác alias thuộc lượt test.
     * Output: keystore đã load; không enumerate hoặc xuất key material. */
    private KeyStore androidKeyStore() throws Exception {
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        return keys;
    }

    /** Chặn test khi invariant sai bằng mã cố định, không giữ dữ liệu được so sánh.
     * Input
     * Param: condition — bất biến cần đúng để tiếp tục probe.
     * Param: code — mã cố định từ source test, không dữ liệu hoặc exception gốc. */
    private static void require(boolean condition, String code) {
        if (!condition) throw new IllegalStateException(code);
    }

    /** Cầu callback test không giữ exception gốc; không thay plugin bằng mock. */
    private static final class CallbackResult<T> implements SecurePreferencesCallback<T> {
        private final CountDownLatch completion = new CountDownLatch(1);
        private T value;
        private boolean failed;

        /** Giữ giá trị tổng hợp trong RAM rồi mở latch cho instrumentation worker.
         * Input
         * Param: result — dữ liệu synthetic hoặc ACK từ plugin. */
        @Override
        public void onSuccess(T result) {
            value = result;
            completion.countDown();
        }

        /** Chỉ giữ cờ lỗi để không lộ exception/key/payload qua test result.
         * Input
         * Param: error — lỗi plugin không đáng tin, không serialize/log. */
        @Override
        public void onError(Exception error) {
            failed = true;
            completion.countDown();
        }

        /** Chờ callback tối đa15giây cho test, không tạo deadline nghiệp vụ của app. */
        private void awaitCompletion() throws InterruptedException {
            require(completion.await(15, TimeUnit.SECONDS), "CALLBACK_TIMEOUT");
        }

        /** Yêu cầu native callback thành công trước bước tiếp theo, không giả ACK bằng timeout. */
        private void requireSuccess() throws InterruptedException {
            awaitCompletion();
            require(!failed, "NATIVE_OPERATION_FAILED");
        }
    }
}
