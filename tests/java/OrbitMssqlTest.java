import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/** Black-box protocol tests for the Java source helper. */
public final class OrbitMssqlTest {
    private final String helper;
    private final String driverJar;

    private OrbitMssqlTest(String helper, String driverJar) {
        this.helper = helper;
        this.driverJar = driverJar;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("helper source and driver JAR are required");
        OrbitMssqlTest test = new OrbitMssqlTest(args[0], args[1]);
        test.retainsConnectionAfterRecoverableErrors();
        test.mapsTrustAndSqlAuthentication();
        test.terminatesAfterConnectionErrors();
        test.rejectsMalformedProtocol();
        System.out.println("PASS OrbitMssql Java helper");
    }

    private void retainsConnectionAfterRecoverableErrors() throws Exception {
        Process process = start();
        writeOneByteAtATime(process.getOutputStream(), request("one", "server.test", "D", false, "VALUES"));
        require(readResponse(process.getInputStream(), "one").equals(
                "{\"ok\":true,\"columns\":[\"value\",\"missing\",\"unicode\"],\"rows\":[[\"line\\nvalue\",null,\"\u03bb\"],[\"NULL\",\"\",\"plain\"]]}"),
                "structured values changed");

        process.getOutputStream().write(request("two", "server.test", "D", false, "ERROR"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "two").equals(
                "{\"ok\":false,\"fatal\":false,\"error\":\"syntax error\"}"), "ordinary error was fatal");

        process.getOutputStream().write(request("three", "server.test", "D", false, "MULTI"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "three").contains("only one tabular result"), "multiple results accepted");

        process.getOutputStream().write(request("four", "server.test", "D", false, "DUPLICATE"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "four").contains("duplicate label"), "duplicate labels accepted");

        process.getOutputStream().write(request("empty", "server.test", "D", false, "EMPTY_LABEL"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "empty").contains("label must not be empty"), "empty label accepted");

        process.getOutputStream().write(request("large", "server.test", "D", false, "LARGE"));
        process.getOutputStream().flush();
        String large = readResponse(process.getInputStream(), "large");
        require(large.length() > 100_000 && large.contains("\"ok\":true"), "large value was truncated");

        process.getOutputStream().write(request("state", "server.test", "D", false, "VALUES"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "state").contains("line\\nvalue"), "connection did not survive errors");

        process.getOutputStream().write(request("five", "server.test", "D", false, "UPDATE"));
        process.getOutputStream().flush();
        require(readResponse(process.getInputStream(), "five").equals(
                "{\"ok\":true,\"columns\":[],\"rows\":[]}"), "non-row result changed");
        process.getOutputStream().close();
        require(process.waitFor() == 0, "retained helper did not close cleanly");
    }

    private void mapsTrustAndSqlAuthentication() throws Exception {
        Process trusted = start();
        trusted.getOutputStream().write(request("trust", "trust.test", "D", true, "UPDATE"));
        trusted.getOutputStream().close();
        require(readResponse(trusted.getInputStream(), "trust").contains("\"ok\":true"), "unsafe trust mapping failed");
        require(trusted.waitFor() == 0, "trusted helper failed");

        Process sql = start();
        sql.getOutputStream().write(request("sql", "sql.test", "S", false, "UPDATE"));
        sql.getOutputStream().close();
        require(readResponse(sql.getInputStream(), "sql").contains("\"ok\":true"), "SQL authentication mapping failed");
        require(sql.waitFor() == 0, "SQL helper failed");
    }

    private void terminatesAfterConnectionErrors() throws Exception {
        Process process = start();
        process.getOutputStream().write(request("fatal", "server.test", "D", false, "CONNECTION_ERROR"));
        process.getOutputStream().flush();
        String response = readResponse(process.getInputStream(), "fatal");
        require(response.equals("{\"ok\":false,\"fatal\":true,\"error\":\"connection lost\"}"), "connection error was not fatal");
        require(process.waitFor() == 0, "fatal response did not close helper cleanly");
    }

    private void rejectsMalformedProtocol() throws Exception {
        processFailure("bad header\n".getBytes(StandardCharsets.US_ASCII), "malformed request header");
        processFailure(
                "ORBIT/1 bad nope 1433 0 0 S 0 1 1 1 0\n".getBytes(StandardCharsets.US_ASCII),
                "field length is not an integer");
        processFailure(
                "ORBIT/1 bad 9 1433 0 0 S 0 1 1 1 0\nshort".getBytes(StandardCharsets.US_ASCII),
                "incomplete request payload");
        processFailure(
                "ORBIT/1 bad 134217729 1433 0 0 S 0 1 1 1 0\n".getBytes(StandardCharsets.US_ASCII),
                "field length is out of range");
        ByteArrayOutputStream invalidUtf8 = new ByteArrayOutputStream();
        invalidUtf8.writeBytes("ORBIT/1 bad 1 1433 0 0 S 0 1 1 1 0\n".getBytes(StandardCharsets.US_ASCII));
        invalidUtf8.write(0xff);
        invalidUtf8.writeBytes("upx".getBytes(StandardCharsets.US_ASCII));
        processFailure(invalidUtf8.toByteArray(), "request payload is not UTF-8");
    }

    private void processFailure(byte[] input, String expectedError) throws Exception {
        Process process = start();
        process.getOutputStream().write(input);
        process.getOutputStream().close();
        require(process.waitFor() != 0, "malformed protocol was accepted");
        String error = new String(process.getErrorStream().readAllBytes(), StandardCharsets.UTF_8);
        require(error.contains(expectedError), "missing diagnostic: " + error);
    }

    private Process start() throws IOException {
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        ProcessBuilder builder = new ProcessBuilder(java, "--class-path", driverJar, helper);
        builder.environment().remove("CLASSPATH");
        builder.environment().remove("JAVA_TOOL_OPTIONS");
        builder.environment().remove("_JAVA_OPTIONS");
        builder.environment().remove("JDK_JAVA_OPTIONS");
        return builder.start();
    }

    private static byte[] request(String marker, String host, String authentication, boolean trust, String statement) {
        String instance = "";
        String database = host.equals("sql.test") ? "" : "testdb";
        String domain = authentication.equals("D") ? "EXAMPLE" : "";
        String user = "orbit";
        String password = "secret";
        List<String> fields = List.of(host, instance, database, domain, user, password, statement);
        List<byte[]> bytes = new ArrayList<>();
        for (String field : fields) bytes.add(field.getBytes(StandardCharsets.UTF_8));
        String header = String.join(" ",
                "ORBIT/1", marker, Integer.toString(bytes.get(0).length), "1433",
                Integer.toString(bytes.get(1).length), Integer.toString(bytes.get(2).length), authentication,
                Integer.toString(bytes.get(3).length), Integer.toString(bytes.get(4).length),
                Integer.toString(bytes.get(5).length), Integer.toString(bytes.get(6).length), trust ? "1" : "0") + "\n";
        ByteArrayOutputStream request = new ByteArrayOutputStream();
        request.writeBytes(header.getBytes(StandardCharsets.US_ASCII));
        for (byte[] field : bytes) request.writeBytes(field);
        return request.toByteArray();
    }

    private static void writeOneByteAtATime(OutputStream output, byte[] request) throws IOException {
        for (byte value : request) output.write(value);
        output.flush();
    }

    private static String readResponse(InputStream input, String marker) throws IOException {
        String header = readLine(input);
        String prefix = "ORBIT/1 " + marker + " ";
        require(header.startsWith(prefix), "response marker mismatch: " + header);
        int length = Integer.parseInt(header.substring(prefix.length()));
        byte[] payload = input.readNBytes(length);
        if (payload.length != length) throw new EOFException("incomplete response payload");
        return new String(payload, StandardCharsets.UTF_8);
    }

    private static String readLine(InputStream input) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        while (true) {
            int value = input.read();
            if (value == -1) throw new EOFException("missing response header");
            if (value == '\n') return line.toString(StandardCharsets.US_ASCII);
            line.write(value);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
