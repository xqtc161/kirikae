{
  description = "Example kirikae deployment";

  inputs = { };

  outputs =
    { self }:
    {
      kirikae = {
        hosts = {
          proxy = {
            targetHost = "10.0.0.1";
            targetUser = "root";
            targetPort = 22;
          };
          database = {
            targetHost = "10.0.0.2";
            targetUser = "deploy";
            targetPort = 22;
          };
          vpn = {
            targetHost = "203.0.113.5";
            targetUser = "root";
            targetPort = 2222;
          };
        };
      };
    };
}
