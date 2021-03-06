<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 *
 * The contents of this file are subject to the Mozilla Public License
 * Version 1.1 (the "License"); you may not use this file except in
 * compliance with the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
 * License for the specific language governing rights and limitations
 * under the License.
 *
 * The Original Code is "VHCS - Virtual Hosting Control System".
 *
 * The Initial Developer of the Original Code is moleSoftware GmbH.
 * Portions created by Initial Developer are Copyright (C) 2001-2006
 * by moleSoftware GmbH. All Rights Reserved.
 *
 * Portions created by the ispCP Team are Copyright (C) 2006-2010 by
 * isp Control Panel. All Rights Reserved.
 *
 * Portions created by the i-MSCP Team are Copyright (C) 2010-2017 by
 * i-MSCP - internet Multi Server Control Panel. All Rights Reserved.
 */

/***********************************************************************************************************************
 * Main
 */

require 'imscp-lib.php';

iMSCP_Events_Aggregator::getInstance()->dispatch(iMSCP_Events::onResellerScriptStart);
check_login('reseller');

$tpl = new iMSCP_pTemplate();
$tpl->define_dynamic([
    'layout'       => 'shared/layouts/ui.tpl',
    'page'         => 'reseller/settings_welcome_mail.tpl',
    'page_message' => 'layout'
]);

if (isset($_POST['uaction']) && $_POST['uaction'] == 'email_setup') {
    $data['subject'] = (isset($_POST['auto_subject'])) ? clean_input($_POST['auto_subject']) : '';
    $data['message'] = (isset($_POST['auto_message'])) ? clean_input($_POST['auto_message']) : '';
    $error = false;

    if ($data['subject'] == '') {
        set_page_message(tr('You must specify a subject.'), 'error');
        $error = true;
    }

    if ($data['message'] == '') {
        set_page_message(tr('You must specify a message.'), 'error');
        $error = true;
    }

    if (!$error) {
        set_welcome_email($_SESSION['user_id'], $data);
        set_page_message(tr('Welcome email template has been updated.'), 'success');
        redirectTo('settings_welcome_mail.php');
    }
}

$data = get_welcome_email($_SESSION['user_id']);

$tpl->assign([
    'TR_PAGE_TITLE'               => tr('Reseller / Customers / Welcome Email'),
    'TR_MESSAGE_TEMPLATE_INFO'    => tr('Message template info'),
    'TR_USER_LOGIN_NAME'          => tr('User login (system) name'),
    'TR_USER_PASSWORD'            => tr('User password'),
    'TR_USER_REAL_NAME'           => tr('User real (first and last) name'),
    'TR_MESSAGE_TEMPLATE'         => tr('Message template'),
    'TR_SUBJECT'                  => tr('Subject'),
    'TR_MESSAGE'                  => tr('Message'),
    'TR_SENDER_EMAIL'             => tr('Reply-To email'),
    'TR_SENDER_NAME'              => tr('Reply-To name'),
    'TR_UPDATE'                   => tr('Update'),
    'TR_USERTYPE'                 => tr('User type (admin, reseller, user)'),
    'TR_BASE_SERVER_VHOST_PREFIX' => tr('URL protocol'),
    'TR_BASE_SERVER_VHOST'        => tr('URL to this admin panel'),
    'TR_BASE_SERVER_VHOST_PORT'   => tr('URL port'),
    'SUBJECT_VALUE'               => tohtml($data['subject']),
    'MESSAGE_VALUE'               => tohtml($data['message']),
    'SENDER_EMAIL_VALUE'          => tohtml($data['sender_email']),
    'SENDER_NAME_VALUE'           => tohtml(!empty($data['sender_name'])) ? $data['sender_name'] : tr('Unknown')
]);

generateNavigation($tpl);
generatePageMessage($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
iMSCP_Events_Aggregator::getInstance()->dispatch(iMSCP_Events::onResellerScriptEnd, ['templateEngine' => $tpl]);
$tpl->prnt();

unsetMessages();
