// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:nil -*-
// vim: ts=8 sw=2 sts=2 expandtab

/*
 * Ceph distributed storage system
 *
 * Copyright (C) 2014 Cloudwatt <libre.licensing@cloudwatt.com>
 * Copyright (C) 2014 Red Hat <contact@redhat.com>
 *
 * Author: Loic Dachary <loic@dachary.org>
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 */

#include <errno.h>
#include <stdlib.h>
#include "arch/probe.h"
#include "arch/intel.h"
#include "erasure-code/ErasureCodePlugin.h"
#include "global/global_context.h"
#include "common/config_proxy.h"
#include "gtest/gtest.h"

using namespace std;

TEST(ErasureCodePlugin, factory)
{
  ErasureCodePluginRegistry &instance = ErasureCodePluginRegistry::instance();
  ErasureCodeProfile profile;
  profile["mapping"] = "DD_";
  profile["layers"] = "[ [ \"DDc\", \"\" ] ]";
  ErasureCodeInterfaceRef erasure_code;
  EXPECT_FALSE(erasure_code);
  EXPECT_EQ(0, instance.factory("lrc",
				g_conf().get_val<std::string>("erasure_code_dir"),
				profile, &erasure_code, &cerr));
  EXPECT_TRUE(erasure_code.get());
}

TEST(ErasureCodePlugin, factory_default_layer_plugin)
{
  ErasureCodePluginRegistry &instance = ErasureCodePluginRegistry::instance();
  {
    ErasureCodeProfile profile;
    profile["k"] = "4";
    profile["m"] = "2";
    profile["l"] = "3";
    profile["default-layer-plugin"] = "jerasure";
    ErasureCodeInterfaceRef erasure_code;
    EXPECT_EQ(0, instance.factory("lrc",
				  g_conf().get_val<std::string>("erasure_code_dir"),
				  profile, &erasure_code, &cerr));
    ASSERT_TRUE(erasure_code.get());
    // the layers are not visible here, TestErasureCodeLrc checks which
    // plugin they use; this only checks that the key is kept
    const ErasureCodeProfile &p = erasure_code->get_profile();
    ASSERT_EQ(1U, p.count("default-layer-plugin"));
    EXPECT_EQ("jerasure", p.find("default-layer-plugin")->second);
  }
  {
    ErasureCodeProfile profile;
    profile["k"] = "4";
    profile["m"] = "2";
    profile["l"] = "3";
    profile["default-layer-plugin"] = "foo";
    ErasureCodeInterfaceRef erasure_code;
    stringstream ss;
    EXPECT_NE(0, instance.factory("lrc",
				  g_conf().get_val<std::string>("erasure_code_dir"),
				  profile, &erasure_code, &ss));
    EXPECT_FALSE(erasure_code);
  }
}

/*
 * Local Variables:
 * compile-command: "cd ../.. ; make -j4 &&
 *   make unittest_erasure_code_plugin_lrc &&
 *   valgrind --tool=memcheck ./unittest_erasure_code_plugin_lrc \
 *      --gtest_filter=*.* --log-to-stderr=true --debug-osd=20"
 * End:
 */
